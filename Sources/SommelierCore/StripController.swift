import CoreGraphics
import Foundation

/// 9o9.12: opening and closing MenuBarAgent's « strip (the overflow chevron). ONE implementation shared by `ItemActivator` (click an
/// item that macOS folded behind the chevron, gdu.65) and `LiveActuator` (a drag across the fold or near it, 9o9.12).
///
/// Live facts (docs/findings-drag.md "The expanded strip"): a click on the chevron expands the strip and it STAYS expanded until the
/// chevron is clicked again (Escape does not close it); while expanded the overflowed items are drawn at real frames.
///
/// The controller owns no state. A caller keeps the `Session` it got from `open` and hands it to `close`; `Session.openedByUs` is how
/// "the user had the strip open before we touched it" is remembered: `close` never clicks a strip that was already expanded.
public struct StripController: Sendable {
    public struct Timing: Sendable {
        /// How long to wait for the strip to show as expanded after the chevron click.
        public var expandTimeout: TimeInterval = 1.0
        /// How long to wait for the strip to collapse after one closing click.
        public var collapseTimeout: TimeInterval = 1.0
        public var poll: TimeInterval = 0.05
        public init() {}
        public init(expandTimeout: TimeInterval, collapseTimeout: TimeInterval, poll: TimeInterval) {
            self.expandTimeout = expandTimeout; self.collapseTimeout = collapseTimeout; self.poll = poll
        }
    }

    /// One strip session: where the chevron was clicked and whether WE opened the strip.
    public struct Session: Equatable, Sendable {
        public var chevronPoint: CGPoint
        /// False when the strip was already expanded (the user opened it): it is then left open on `close`.
        public var openedByUs: Bool
        public var openedAt: Date
    }

    public enum OpenOutcome: Equatable, Sendable {
        case ready(Session)
        /// The chevron click could not be posted; nothing changed.
        case clickFailed
        /// A mouse button is pressed; refused, nothing clicked.
        case mouseBusy
        /// The strip never became ready within the timeout (`session` is set when we DID click, so the caller must `close` it).
        case timedOut(Session?)
        case cancelled(Session?)
    }

    let click: @Sendable (CGPoint) -> Bool
    let probe: @Sendable () async -> OverflowProbe?
    let pressedButtons: @Sendable () -> Int
    let sleep: @Sendable (TimeInterval) async -> Void
    let now: @Sendable () -> Date
    var timing: Timing

    public init(click: @escaping @Sendable (CGPoint) -> Bool, probe: @escaping @Sendable () async -> OverflowProbe?,
                pressedButtons: @escaping @Sendable () -> Int, sleep: @escaping @Sendable (TimeInterval) async -> Void,
                now: @escaping @Sendable () -> Date, timing: Timing = Timing()) {
        self.click = click; self.probe = probe; self.pressedButtons = pressedButtons; self.sleep = sleep; self.now = now; self.timing = timing
    }

    /// What a probe shows about the strip, apart from the rule's verdict: compared before and after OUR click (gdu.126).
    struct Signature: Equatable {
        var description: String?
        var chevron: CGRect?
        var left: [CGRect]
        init(_ p: OverflowProbe) {
            description = p.chevronDescription; chevron = p.chevron
            left = p.hosted.filter { h in p.chevron.map { h.minX < $0.minX } ?? false }.sorted { ($0.minX, $0.width) < ($1.minX, $1.width) }
        }
        /// The chevron's description or the pile's layout differs (the chevron frame alone does not count: it slides while settling).
        func changed(from other: Signature) -> Bool { description != other.description || left != other.left }
    }

    /// Opens the strip. `checkAlreadyExpanded`: read the probe first and, when the strip is already expanded (the user opened it),
    /// click nothing and report `openedByUs == false`. Otherwise click the chevron (70 ms hold) and poll `ready` until it says true.
    /// `ready` is the caller's own readiness test (e.g. "the item's frame is real and equal on two polls"); it runs on every poll.
    ///
    /// gdu.126: when `ready` never becomes true after OUR click, the LAST probe decides, never leaving an undetected-open strip:
    /// the shared `StripExpansionRule` says open and `acceptOpenOnTimeout` -> `.ready` (treated as open); says collapsed but the chevron's
    /// description or the pile's layout changed since before the click -> ONE closing click, verified against the pre-click state; nothing
    /// changed -> `.timedOut` with no closing click (there is nothing to close).
    public func open(chevron: CGRect, checkAlreadyExpanded: Bool, acceptOpenOnTimeout: Bool = false, ready: () async -> Bool,
                     say: (String) -> Void, isolation: isolated (any Actor)? = #isolation) async -> OpenOutcome {
        let point = CGPoint(x: chevron.midX, y: chevron.midY)
        var clickedAt = now()
        var openedByUs = true
        var baseline: Signature?
        if checkAlreadyExpanded, let p = await probe() {
            baseline = Signature(p)
            if p.isOpen {
                openedByUs = false
                say("phase overflow: the strip is already expanded (opened by the user, \(p.expansionClause?.rawValue ?? "flag")); it will be left open")
            }
        } else if !checkAlreadyExpanded, let p = await probe() { baseline = Signature(p) }
        if openedByUs {
            if pressedButtons() != 0 { return .mouseBusy }
            guard click(point) else { return .clickFailed }
            clickedAt = now()
            say("phase overflow: chevron clicked at \(Int(point.x)),\(Int(point.y)); waiting for the expanded strip")
        }
        let session = Session(chevronPoint: point, openedByUs: openedByUs, openedAt: clickedAt)
        while true {
            if Task.isCancelled { return .cancelled(openedByUs ? session : nil) }
            if await ready() { return .ready(session) }
            if now().timeIntervalSince(clickedAt) > timing.expandTimeout { break }
            await sleep(timing.poll)
        }
        guard openedByUs else { return .timedOut(nil) }
        // Not ready in time. Ask the shared rule once more before giving up.
        guard let last = await probe() else { return .timedOut(session) }
        if let clause = last.expansionClause ?? (last.expanded ? .geometric : nil) {
            say("phase overflow: the strip is open (\(clause.rawValue)) though it did not settle in time")
            return acceptOpenOnTimeout ? .ready(session) : .timedOut(session)
        }
        guard let baseline, Signature(last).changed(from: baseline) else {
            say("phase overflow: the strip did not change after the click; nothing to close")
            return .timedOut(session)
        }
        // Collapsed per the rule, yet the chevron or the pile changed: the strip may be open and undetected. One closing click, verified
        // against the state before our click.
        say("phase overflow: the strip looks changed but is not recognised as open; posting one closing click")
        guard click(CGPoint(x: (last.chevron ?? chevron).midX, y: (last.chevron ?? chevron).midY)) else { return .timedOut(session) }
        let start = now()
        while now().timeIntervalSince(start) < timing.collapseTimeout {
            await sleep(timing.poll)
            if let p = await probe(), !p.isOpen, !Signature(p).changed(from: baseline) {
                say("phase overflow: strip back to its state before the click (closing click verified)")
                return .timedOut(nil)
            }
        }
        say("phase overflow: strip state after the closing click is not the one before the click")
        return .timedOut(session)
    }

    /// `open` with the standard readiness test: the probe says expanded, and the chevron and every hosted frame are equal on two polls in
    /// a row (the strip finished sliding). Used by the actuator and by `mbprobe overflow expand` / `drag --strip`.
    public func openSteady(chevron: CGRect, say: (String) -> Void, isolation: isolated (any Actor)? = #isolation) async -> OpenOutcome {
        var previous: [CGRect]?
        let probe = self.probe
        return await open(chevron: chevron, checkAlreadyExpanded: true, acceptOpenOnTimeout: true, ready: {
            guard let pr = await probe(), pr.isOpen, let c = pr.chevron else { previous = nil; return false }
            let sig = [c] + pr.hosted
            defer { previous = sig }
            return previous == sig
        }, say: say)
    }

    /// Closes the strip WE opened with clicks on the chevron (Escape does not close it, seen live): two tries, each waiting up to
    /// `collapseTimeout` for `expanded == false`. Returns nil when it is closed (or was not ours to close), otherwise a note:
    /// `overflowStripStillExpanded` after the closing clicks, `overflowStripStateUnknown` when the probe cannot be read.
    public func close(_ session: Session?, say: (String) -> Void, isolation: isolated (any Actor)? = #isolation) async -> String? {
        guard let session, session.openedByUs else { return nil }
        return await collapse(chevronAt: session.chevronPoint, say: say)
    }

    /// Unconditional collapse (the caller knows the strip is open, or `mbprobe overflow collapse`): same as `close` for a session of ours.
    public func collapse(chevronAt point: CGPoint, say: (String) -> Void, isolation: isolated (any Actor)? = #isolation) async -> String? {
        guard let probe = await probe() else {
            say("overflow: probe unavailable at collapse; strip state unknown")
            return "overflowStripStateUnknown"
        }
        // gdu.126: the shared rule decides (flag, description, geometry or a de-stacked pile), and the log says which clause.
        guard probe.isOpen else { say("phase strip: already closed"); return nil }   // found collapsed: no click was posted
        say("phase strip: open per \(probe.expansionClause?.rawValue ?? "flag"); closing")
        let at = probe.chevron.map { CGPoint(x: $0.midX, y: $0.midY) } ?? point
        for attempt in 1...2 {
            guard click(at) else { break }
            let start = now()
            while now().timeIntervalSince(start) < timing.collapseTimeout {
                await sleep(timing.poll)
                if let p = await self.probe(), !p.isOpen {
                    say("phase overflow: strip collapsed (\(attempt) click\(attempt == 1 ? "" : "s"))")
                    return nil
                }
            }
        }
        say("phase overflow: strip still expanded after the closing clicks")
        return "overflowStripStillExpanded"
    }
}

/// A synthetic left/right click (move, 30 ms, down, 70 ms hold, up). Hosted status items drop clicks held under ~40 ms (gdu.62).
public enum SyntheticClick {
    public static func post(at point: CGPoint, button: ClickButton) -> Bool {
        let (down, up, b): (CGEventType, CGEventType, CGMouseButton) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: b),
              let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: b) else { return false }
        d.setIntegerValueField(.mouseEventClickState, value: 1)
        u.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        d.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.07)
        u.post(tap: .cghidEventTap)
        return true
    }
}
