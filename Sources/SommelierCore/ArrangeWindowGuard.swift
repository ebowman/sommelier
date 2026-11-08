import Foundation

/// Decides when the Arrange window floats above other windows (gdu.100) and how it ends an engine action (gdu.136).
///
/// Sommelier is an accessory app, so the menu bar belongs to the last active regular app. When the engine Command-drags a
/// status item, macOS activates that app and its windows would cover Arrange. While an action is in flight the window floats.
///
/// gdu.136 invariant: the window ends an action at least as visible as it began it. The decision is taken from a snapshot at FLOAT
/// time, never from activation state at restore time: `wasVisible` (on screen and unoccluded) means the window is ordered front
/// again afterwards (without stealing key focus), `wasKeyOrActive` (the window was key, the app was active, or an activation requested
/// by a restore in the last `reactivationWindow` seconds is still settling) means the app takes activation back as well.
public struct ArrangeWindowGuard {
    public enum Command: Equatable {
        case float
        case restore(orderFront: Bool, reactivate: Bool)
    }

    /// How long a requested reactivation counts as pending: activation is asynchronous and `NSApp.isActive` lags it.
    public static let reactivationWindow: TimeInterval = 2

    private var floated = false
    private var wasVisible = false
    private var wasKeyOrActive = false
    private var reactivationPendingUntil: Date?

    public init() {}

    public func reactivationPending(at now: Date) -> Bool { reactivationPendingUntil.map { now < $0 } ?? false }

    /// - windowVisible: the window is on screen and unoccluded (`isVisible && occlusionState.contains(.visible)`).
    /// - windowOnScreen: the window still exists on screen at all (open, not miniaturized), though it may be covered.
    /// - windowKey: the window is the key window.
    public mutating func update(inFlight: Bool, windowVisible: Bool, appActive: Bool, windowKey: Bool = false,
                                windowOnScreen: Bool = true, now: Date = Date()) -> Command? {
        if floated {
            if !windowOnScreen {   // closed or miniaturized mid-flight: really gone, nothing to bring back
                floated = false
                return .restore(orderFront: false, reactivate: false)
            }
            // A floating window covered for a moment (strip overlay, HUD) is not gone: keep the float until the action ends.
            if inFlight { return nil }
            floated = false
            if wasKeyOrActive { reactivationPendingUntil = now.addingTimeInterval(Self.reactivationWindow) }
            return .restore(orderFront: wasVisible, reactivate: wasKeyOrActive)
        }
        if inFlight && windowVisible {
            floated = true
            wasVisible = true
            wasKeyOrActive = windowKey || appActive || reactivationPending(at: now)
            return .float
        }
        return nil
    }
}
