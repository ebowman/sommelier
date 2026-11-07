import Foundation

/// Which Arrange-window affordances exist (8z5.5). Pure so the views stay free of policy.
public enum ArrangeMenuRules {
    /// "Move left" / "Move right": always available for a Visible row except ghosts (they are not on the bar to step).
    public static func showsStepItems(isGhost: Bool) -> Bool { !isGhost }

    /// gdu.113: a running ghost (listed Visible, not on the bar: hidden in Control Center or still arriving) can be dragged to another section and gets the section-move menu; its own drop inside Visible is a show request (gdu.110).
    public static func ghostInteractive(_ row: ArrangeRow) -> Bool {
        row.isGhost && !row.notRunning && row.draggable && !row.isAnchor
    }
}
