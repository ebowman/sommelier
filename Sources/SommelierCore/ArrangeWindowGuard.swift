/// Decides when the Arrange window floats above other windows (gdu.100).
///
/// Sommelier is an accessory app, so the menu bar belongs to the last active regular app. When the engine Command-drags a
/// status item, macOS activates that app and its windows would cover Arrange. While an action is in flight the window floats;
/// afterwards it returns to normal level and, if Sommelier was active when the action began, takes activation back.
public struct ArrangeWindowGuard {
    public enum Command: Equatable {
        case float
        case restore(reactivate: Bool)
    }

    private var floated = false
    private var wasActive = false

    public init() {}

    public mutating func update(inFlight: Bool, windowVisible: Bool, appActive: Bool) -> Command? {
        if floated {
            if !windowVisible {
                floated = false
                return .restore(reactivate: false)
            }
            if !inFlight {
                floated = false
                return .restore(reactivate: wasActive)
            }
            return nil
        }
        if inFlight && windowVisible {
            floated = true
            wasActive = appActive
            return .float
        }
        return nil
    }
}
