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

/// Live monitor: `NSEvent.addGlobalMonitorForEvents` for left mouse down/up (no Accessibility or Input Monitoring grant is needed
/// for mouse events). The Command flag is read from the mouse-down event itself, so `.flagsChanged` is not monitored: releasing
/// Command mid-drag does not end the drag, only the mouse-up does (the engine also treats a drag older than
/// `Config.arrangeDragMaxAge` as lost).
public final class LiveHandDragMonitor: HandDragMonitor {
    private var monitor: Any?
    private var dragging = false
    public init() {}

    public func start(_ handler: @escaping @Sendable (HandDragEvent) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown:
                let rects = HandDragRule.menuBarRects(
                    screens: NSScreen.screens.map { ($0.frame, $0.safeAreaInsets.top) }, thickness: NSStatusBar.system.thickness)
                guard HandDragRule.isHandDragStart(commandHeld: event.modifierFlags.contains(.command), point: NSEvent.mouseLocation, rects: rects) else { return }
                self.dragging = true
                handler(.began)
            case .leftMouseUp:
                guard self.dragging else { return }
                self.dragging = false
                handler(.ended)
            default: break
            }
        }
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        dragging = false
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
