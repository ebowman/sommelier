import CoreGraphics
import Foundation

/// Whether the Command modifier is stuck down in the system flags state (sommelier-9o9.20).
public protocol ModifierStateProviding: Sendable {
    var isCommandLatched: Bool { get }
}

/// Reads the real flags state (`combinedSessionState` and `hidSystemState`). Needs no permission. Not used by tests.
public struct ModifierState: ModifierStateProviding {
    public init() {}
    public var combinedSession: CGEventFlags { CGEventSource.flagsState(.combinedSessionState) }
    public var hid: CGEventFlags { CGEventSource.flagsState(.hidSystemState) }
    public var isCommandLatched: Bool {
        combinedSession.contains(.maskCommand) || hid.contains(.maskCommand)
    }
}

/// After a synthetic drag: if Command is still latched, post the key-up once more and re-check (never loops).
public enum DragModifierGuard {
    /// Returns true when the modifier state is clear at the end. `postKeyUp` posts one Command key-up.
    @discardableResult
    public static func settle(state: ModifierStateProviding, postKeyUp: () -> Void,
                              sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                              log: (String) -> Void) -> Bool {
        guard state.isCommandLatched else { return true }
        log("drag: modifier still latched; posted key-up")
        postKeyUp()
        sleep(0.1)
        if state.isCommandLatched {
            log("drag: modifier STILL latched")
            return false
        }
        log("drag: modifier state clear")
        return true
    }
}
