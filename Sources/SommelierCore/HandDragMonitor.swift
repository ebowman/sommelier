import AppKit
import Foundation

/// 9o9.7: a Command-drag done BY HAND in the menu bar is the user changing their mind: the engine pauses while it lasts and adopts
/// the resulting order into the record afterwards (`LayoutEngine.handDragEvent`). The monitor reports EVERY such drag it sees,
/// Sommelier's own synthetic ones included; the engine discards those by its actuator-in-flight flag, never by event introspection.
public enum HandDragEvent: Sendable, Equatable {
    /// Left button went down with Command held inside a menu bar rect.
    case began
    /// The left button came up after a `began`.
    case ended
}

/// Source of hand-drag events, behind a protocol so tests use a fake.
public protocol HandDragMonitor: AnyObject {
    func start(_ handler: @escaping @Sendable (HandDragEvent) -> Void)
    func stop()
}

/// The detection rule (pure, so it is testable without a window server).
public enum HandDragRule {
    /// One rect per screen in global (bottom-left origin, NSEvent) coordinates: the full screen width, `max(thickness, safeAreaInsets.top)`
    /// tall at the top edge (a notch display's menu bar is as tall as its top safe-area inset).
    public static func menuBarRects(screens: [(frame: CGRect, safeAreaTop: CGFloat)], thickness: CGFloat) -> [CGRect] {
        screens.map { s in
            let h = max(thickness, s.safeAreaTop)
            return CGRect(x: s.frame.minX, y: s.frame.maxY - h, width: s.frame.width, height: h)
        }
    }

    /// A hand drag starts when the left button goes down with Command held while the pointer is inside any menu bar rect
    /// (edges inclusive: the pointer at the very top row of a screen reports y == maxY).
    public static func isHandDragStart(commandHeld: Bool, point: CGPoint, rects: [CGRect]) -> Bool {
        guard commandHeld else { return false }
        return rects.contains { point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY }
    }
}

/// The hand-drag state machine shared by both event sources (gdu.147): a left-down with Command held inside a menu bar rect begins a
/// drag, the next left-up ends it. A plain click (no Command) never begins one, whichever process the event was delivered to. Pure of
/// AppKit so it is unit-testable with injected events.
public final class HandDragTracker: @unchecked Sendable {
    public enum Phase: Sendable { case down, up }
    private let lock = NSLock()
    private var dragging = false
    private let handler: @Sendable (HandDragEvent) -> Void
    public init(_ handler: @escaping @Sendable (HandDragEvent) -> Void) { self.handler = handler }

    public func handle(_ phase: Phase, commandHeld: Bool, point: CGPoint, rects: [CGRect]) {
        switch phase {
        case .down:
            guard HandDragRule.isHandDragStart(commandHeld: commandHeld, point: point, rects: rects) else { return }
            lock.lock(); dragging = true; lock.unlock()
            handler(.began)
        case .up:
            lock.lock(); let was = dragging; dragging = false; lock.unlock()
            if was { handler(.ended) }
        }
    }
    public func reset() { lock.lock(); dragging = false; lock.unlock() }
}

/// Live monitor: a GLOBAL monitor (events for other processes) plus a LOCAL monitor (events delivered to this process, which the
/// global one never sees: a hand drag that starts on Sommelier's own status item). Both feed one `HandDragTracker`; the local one
/// returns the event unchanged. No Accessibility or Input Monitoring grant is needed for mouse events. The Command flag is read from
/// the mouse-down event itself, so releasing Command mid-drag does not end the drag, only the mouse-up does (the engine also treats a
/// drag older than `Config.arrangeDragMaxAge` as lost). The engine's own synthetic drags are discarded by the actuator-in-flight flag
/// in the handler the engine installs, exactly as before.
public final class LiveHandDragMonitor: HandDragMonitor {
    private var monitors: [Any] = []
    private var tracker: HandDragTracker?
    public init() {}

    public func start(_ handler: @escaping @Sendable (HandDragEvent) -> Void) {
        guard monitors.isEmpty else { return }
        let t = HandDragTracker(handler)
        tracker = t
        let feed: @Sendable (NSEvent) -> Void = { event in
            switch event.type {
            case .leftMouseDown:
                let rects = HandDragRule.menuBarRects(
                    screens: NSScreen.screens.map { ($0.frame, $0.safeAreaInsets.top) }, thickness: NSStatusBar.system.thickness)
                t.handle(.down, commandHeld: event.modifierFlags.contains(.command), point: NSEvent.mouseLocation, rects: rects)
            case .leftMouseUp:
                t.handle(.up, commandHeld: false, point: .zero, rects: [])
            default: break
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { feed($0) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { feed($0); return $0 }) { monitors.append(l) }
    }

    public func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        tracker?.reset()
        tracker = nil
    }
}

/// The hand drag in progress (thread-safe: the monitor calls on the main thread, the engine reads from its actor).
final class HandDragBox: @unchecked Sendable {
    private let lock = NSLock()
    private var since: Date?
    private var serial = 0
    func begin(now: Date, flightSerial: Int) { lock.lock(); since = now; serial = flightSerial; lock.unlock() }
    /// A `began` seen while the actuator was dragging: ours; its `ended` is ignored too.
    func ignoreCurrent() { lock.lock(); since = nil; lock.unlock() }
    /// The flight serial at the drag's start, or nil when no hand drag was in progress (none, or an ignored synthetic one).
    func end() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard since != nil else { return nil }
        since = nil
        return serial
    }
    func active(now: Date, maxAge: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = since else { return false }
        return now.timeIntervalSince(s) < maxAge
    }
}

/// "A Sommelier actuator call is in flight" (it posts synthetic Command-drags). `serial` counts the calls started, so "no Sommelier
/// move since the drag began" is `serial` unchanged and nothing in flight.
final class ActuatorFlightBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var started = 0
    func begin() { lock.lock(); count += 1; started += 1; lock.unlock() }
    func end() { lock.lock(); count = max(0, count - 1); lock.unlock() }
    var inFlight: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    var serial: Int { lock.lock(); defer { lock.unlock() }; return started }
}
