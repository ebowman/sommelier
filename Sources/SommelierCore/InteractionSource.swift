import AppKit
import CoreGraphics
import Foundation

/// 9o9.4: the machine's "the user is doing something" signals, behind a protocol so tests use fakes. The engine asks before EVERY
/// actuator call; a non-nil answer is the reason the call must wait (logged as "engine: paused: <reason>").
public protocol InteractionSource: Sendable {
    /// nil = nothing is in the way. Otherwise a short human reason: "a menu is open", "the mouse button is down",
    /// "a modifier key is held", "the screen is locked", "the display is asleep".
    func blockingReason() -> String?
}

/// Real signals. Reads are cheap and synchronous (event-source state, the session dictionary, the window list).
public struct LiveInteractionSource: InteractionSource {
    public init() {}

    public func blockingReason() -> String? {
        if Self.screenLocked() { return "the screen is locked" }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return "the display is asleep" }
        if Self.mouseDown() { return "the mouse button is down" }
        if Self.modifierHeld() { return "a modifier key is held" }
        if Self.menuOpen() { return "a menu is open" }
        return nil
    }

    static func mouseDown() -> Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }

    static func modifierHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty
    }

    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true || (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// A pop-up menu (any app's, including a status item's) is an on-screen window at the pop-up-menu level.
    static func menuOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == level else { return false }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { return false }
            if let b = w[kCGWindowBounds as String] as? [String: Any], let h = b["Height"] as? Double, h <= 1 { return false }
            return true
        }
    }
}

/// Thread-safe "an Arrange drag is in flight" flag with the time it was raised, so a lost "ended" event cannot pause the engine forever.
final class ArrangeDragBox: @unchecked Sendable {
    private let lock = NSLock()
    private var since: Date?
    func set(_ on: Bool, now: Date) { lock.lock(); since = on ? (since ?? now) : nil; lock.unlock() }
    func active(now: Date, maxAge: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let s = since else { return false }
        return now.timeIntervalSince(s) < maxAge
    }
}
