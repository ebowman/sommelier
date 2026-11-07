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
        if Self.screenLocked() { return Self.screenLockedReason }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return Self.displayAsleepReason }
        if Self.mouseDown() { return "the mouse button is down" }
        if Self.modifierHeld() { return "a modifier key is held" }
        if Self.menuOpen() { return Self.menuOpenReason }
        return nil
    }

    /// The reason strings the engine keys on (backoff/staleness), shared so a rename cannot desynchronise them.
    public static let menuOpenReason = "a menu is open"
    public static let screenLockedReason = "the screen is locked"
    public static let displayAsleepReason = "the display is asleep"
    /// 9o9.7: the user is Command-dragging in the menu bar by hand (reported by the engine's hand-drag monitor, not read here).
    public static let handDragReason = "you are dragging in the menu bar"

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

    /// A pop-up menu (any other app's, including a status item's) is an on-screen window at the pop-up-menu level that is
    /// menu-sized (height >= 20, width >= 40), visible (alpha > 0) and not one of Sommelier's own windows.
    static func menuOpen() -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == level else { return false }
            if (w[kCGWindowOwnerPID as String] as? Int) == me { return false }
            if let a = w[kCGWindowAlpha as String] as? Double, a <= 0 { return false }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let h = b["Height"] as? Double, let wd = b["Width"] as? Double else { return false }
            return h >= 20 && wd >= 40
        }
    }
}

/// 9o9.8: "the user came back" signals (display wake, session active, screen unlocked), behind a protocol so tests can fire them.
public protocol WakeSignalSource: AnyObject {
    func start(_ handler: @escaping @Sendable () -> Void)
    func stop()
}

public final class LiveWakeSignals: WakeSignalSource {
    private var workspaceTokens: [any NSObjectProtocol] = []
    private var distributedToken: (any NSObjectProtocol)?
    public init() {}

    public func start(_ handler: @escaping @Sendable () -> Void) {
        guard workspaceTokens.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in handler() })
        }
        distributedToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in handler() }
    }

    public func stop() {
        for t in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        workspaceTokens = []
        if let d = distributedToken { DistributedNotificationCenter.default().removeObserver(d) }
        distributedToken = nil
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
