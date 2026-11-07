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
    /// `arm` is a pause between landing on the source item and mouse-down (hover-arm); `preUp` is a pause on the
    /// drop point between the last dragged event and mouse-up. Both default to 0 (the gdu.7 behaviour).
    public static func make(from start: CGPoint, toX targetX: CGFloat, steps: Int,
                            stepDelay: TimeInterval, hold: TimeInterval,
                            arm: TimeInterval = 0, preUp: TimeInterval = 0) -> [DragStep] {
        let n = max(1, steps)
        var out: [DragStep] = [
            DragStep(kind: .move, point: start, delayBefore: 0),
            DragStep(kind: .down, point: start, delayBefore: max(0.02, arm)),
        ]
        for i in 1...n {
            let x = start.x + (targetX - start.x) * CGFloat(i) / CGFloat(n)
            out.append(DragStep(kind: .dragged, point: CGPoint(x: x, y: start.y), delayBefore: i == 1 ? hold : stepDelay))
        }
        out.append(DragStep(kind: .up, point: CGPoint(x: targetX, y: start.y), delayBefore: max(stepDelay, preUp)))
        return out
    }

    /// Step count that keeps the per-step distance at or below `maxStepPx` (never fewer than `steps`).
    public static func stepsCapping(distance: CGFloat, steps: Int, maxStepPx: CGFloat?) -> Int {
        guard let m = maxStepPx, m > 0 else { return steps }
        return max(steps, Int((abs(distance) / m).rounded(.up)))
    }
}

/// One event of a traced drag: where it was meant to go, where the cursor actually was right after posting, and when.
public struct DragTraceEvent: Sendable {
    public var kind: DragStep.Kind
    public var planned: CGPoint
    public var actual: CGPoint
    /// Milliseconds since the first event of the drag.
    public var tMS: Double
}

/// Synthesizes Cmd+drag on the menu bar.
public struct DragMover {
    public var steps: Int
    public var stepDelay: TimeInterval
    public var holdTime: TimeInterval
    /// Hover on the source item this long before mouse-down (0 = none).
    public var armTime: TimeInterval
    /// Hover on the drop point this long before mouse-up (0 = none).
    public var preUpHover: TimeInterval
    /// Cap on the per-step distance in points (raises the step count when needed); nil = off.
    public var maxStepPx: CGFloat?
    /// Where every synthesized event goes (default: the HID event tap). Injectable so tests capture the sequence.
    public var poster: @Sendable (CGEvent) -> Void

    public init(steps: Int = 10, stepDelay: TimeInterval = 0.015, holdTime: TimeInterval = 0.1,
                armTime: TimeInterval = 0, preUpHover: TimeInterval = 0, maxStepPx: CGFloat? = nil,
                poster: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.poster = poster
        self.steps = steps; self.stepDelay = stepDelay; self.holdTime = holdTime
        self.armTime = armTime; self.preUpHover = preUpHover; self.maxStepPx = maxStepPx
    }

    /// Drags the item's center to `targetX` (same y). Returns the time the mouse-up was posted.
    /// Guarantees that a mouseUp is posted whenever a mouseDown was (even when later event creation fails).
    @discardableResult
    public func move(itemFrame: CGRect, toX targetX: CGFloat) throws -> Date {
        try moveTraced(itemFrame: itemFrame, toX: targetX).upAt
    }

    /// Like `move`, also returning the per-event trace (planned vs actual cursor location, timestamps).
    public func moveTraced(itemFrame: CGRect, toX targetX: CGFloat) throws -> (upAt: Date, trace: [DragTraceEvent]) {
        if NSEvent.pressedMouseButtons != 0 { throw DragError.userBusy }
        let start = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        let n = DragPlan.stepsCapping(distance: targetX - start.x, steps: steps, maxStepPx: maxStepPx)
        let plan = DragPlan.make(from: start, toX: targetX, steps: n, stepDelay: stepDelay, hold: holdTime,
                                 arm: armTime, preUp: preUpHover)
        let saved = CGEvent(source: nil)?.location ?? .zero
        defer { CGWarpMouseCursorPosition(saved) }
        let r = perform(plan: plan, src: CGEventSource(stateID: .hidSystemState),
                        sleep: { Thread.sleep(forTimeInterval: $0) }, warp: { CGWarpMouseCursorPosition($0) })
        if let err = r.error { throw err }
        Thread.sleep(forTimeInterval: 0.05)
        return (r.upAt, r.trace)
    }

    /// Virtual key code of the (left) Command key.
    public static let commandKeyCode: CGKeyCode = 0x37

    /// A Command key-up `flagsChanged` event with no flags (clears a latched Command in the HID/session flags state).
    static func commandKeyUpEvent(source: CGEventSource?) -> CGEvent? {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false) else { return nil }
        e.type = .flagsChanged
        e.flags = []
        return e
    }

    /// Posts the Command key-up on this mover's tap. Returns false when the event could not be created.
    @discardableResult
    public func postCommandKeyUp() -> Bool {
        guard let e = Self.commandKeyUpEvent(source: CGEventSource(stateID: .hidSystemState)) else { return false }
        poster(e)
        return true
    }

    /// Runs the plan, posting through `poster`: Command-flagged move/down/dragged events, a flag-less mouse-up, then
    /// (always, even on failure) an explicit Command key-up so the modifier is never left latched (sommelier-9o9.20).
    func perform(plan: [DragStep], src: CGEventSource?, sleep: (TimeInterval) -> Void, warp: (CGPoint) -> Void)
        -> (upAt: Date, error: DragError?, trace: [DragTraceEvent])
    {
        var trace: [DragTraceEvent] = []
        var t0: Date?
        let poster = self.poster
        let outcome = Self.execute(plan: plan, sleep: sleep, post: { s in
            let type: CGEventType
            switch s.kind {
            case .move: type = .mouseMoved
            case .down: type = .leftMouseDown
            case .dragged: type = .leftMouseDragged
            case .up: type = .leftMouseUp
            }
            if s.kind == .move { warp(s.point) }
            // Event creation with the shared source can fail; a nil-source event is an acceptable last resort for the up.
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: s.point, mouseButton: .left)
                    ?? (s.kind == .up ? CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: s.point, mouseButton: .left) : nil)
            else { return false }
            e.flags = s.kind == .up ? [] : .maskCommand
            poster(e)
            let now = Date()
            if t0 == nil { t0 = now }
            trace.append(DragTraceEvent(kind: s.kind, planned: s.point, actual: CGEvent(source: nil)?.location ?? .zero,
                                        tMS: now.timeIntervalSince(t0!) * 1000))
            return true
        })
        if let up = Self.commandKeyUpEvent(source: src) ?? Self.commandKeyUpEvent(source: nil) { poster(up) }
        return (outcome.upAt, outcome.error, trace)
    }

    /// Runs a plan through `post` (returns false when the event could not be created). If creation fails after a
    /// mouseDown was posted and before the mouseUp, a mouseUp at the last point is posted before reporting the error,
    /// so the button is never left pressed. Pure apart from the closures (unit-testable).
    static func execute(plan: [DragStep], sleep: (TimeInterval) -> Void, post: (DragStep) -> Bool)
        -> (upAt: Date, error: DragError?)
    {
        var upAt = Date()
        var downPosted = false, upPosted = false
        var last = plan.first?.point ?? .zero
        for s in plan {
            if s.delayBefore > 0 { sleep(s.delayBefore) }
            guard post(s) else {
                if downPosted && !upPosted {
                    _ = post(DragStep(kind: .up, point: last, delayBefore: 0))
                }
                return (Date(), .eventCreationFailed)
            }
            last = s.point
            if s.kind == .down { downPosted = true }
            if s.kind == .up { upPosted = true; upAt = Date() }
        }
        return (upAt, nil)
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
    /// First / last movable on-bar slot (the caller passes `order` without system modules for `rightmost`).
    case leftmost, rightmost
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
        case .leftmost, .rightmost: return nil   // the actuator turns these into before/after of a concrete neighbor
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
        case .leftmost: return i == 0
        case .rightmost: return i == order.count - 1
        }
    }
}

public extension DragRelation {
    /// String-keyed form of an ItemKey relation (keys compared by `ItemKey.description`).
    init(_ r: Relation) {
        switch r {
        case .before(let k): self = .before(k.description)
        case .after(let k): self = .after(k.description)
        case .leftmost: self = .leftmost
        case .rightmost: self = .rightmost
        }
    }
}
