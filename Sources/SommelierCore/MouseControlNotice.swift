/// Decides when the "Sommelier is moving <item>; hands off the mouse" HUD is shown (gdu.103). Pure: the app polls it with
/// `EngineState.inFlight` and forwards the returned command. Only `.move` drives the real pointer (a synthetic Command-drag);
/// hide/show go through Control Center and never touch the mouse.
public struct MouseControlNotice {
    public enum Command: Equatable {
        case show(text: String)
        case hide
    }

    private var shownText: String?

    public init() {}

    public mutating func update(inFlight: PlannedAction?, enabled: Bool, displayName: (ItemKey) -> String) -> Command? {
        guard enabled, case .move(let key, _)? = inFlight else {
            guard shownText != nil else { return nil }
            shownText = nil
            return .hide
        }
        let text = "Sommelier is moving \(displayName(key)) on the menu bar. Hands off the mouse for a moment."
        guard text != shownText else { return nil }
        shownText = text
        return .show(text: text)
    }
}
