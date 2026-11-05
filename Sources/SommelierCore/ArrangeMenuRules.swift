import Foundation

/// Which Arrange-window affordances exist in each order mode (8z5.5). Pure so the views stay free of policy.
public enum ArrangeMenuRules {
    /// "Move left" / "Move right" exist only when Sommelier enforces an order for placed items.
    public static func showsStepItems(mode: OrderMode) -> Bool { mode == .placedOnly }

    /// Context-menu title of the placement item; nil for an item that is not placed.
    /// placedOnly: "Stop managing order"; macOSOwns nothing is managed, so "Forget placement" (same action).
    public static func placementMenuTitle(row isPlaced: Bool, mode: OrderMode) -> String? {
        guard isPlaced else { return nil }
        return mode == .placedOnly ? "Stop managing order" : "Forget placement"
    }

    /// Second subtitle line of the Visible strip; nil when Sommelier keeps the order itself.
    public static func visibleHint(mode: OrderMode) -> String? {
        mode == .macOSOwns ? "Order follows macOS; Command-drag items in the menu bar to reorder." : nil
    }

    /// SF Symbol for a placed capsule: `pin.fill` when enforced, `pin.slash` when remembered but inert; nil when not placed.
    public static func placementSymbol(isPlaced: Bool, inert: Bool) -> String? {
        guard isPlaced else { return nil }
        return inert ? "pin.slash" : "pin.fill"
    }
}
