import Foundation

/// Which Arrange-window affordances exist (8z5.5). Pure so the views stay free of policy.
public enum ArrangeMenuRules {
    /// "Move left" / "Move right": always present for a Visible row (9o9.5: the strip is the record; every row, ghosts included, is in it).
    public static func showsStepItems() -> Bool { true }

    /// 9o9.5: "Try again" on a row the engine could not place (failed, unsupported, gave up): calls `LayoutEngine.retry(key:)`.
    public static func showsTryAgain(_ row: ArrangeRow) -> Bool {
        if case .cannotPlace? = row.barState { return true }
        if row.pinDownTimedOut { return true }   // 9o9.29
        return false
    }

    /// 9o9.5: the plain-words "why" for a row whose bar state is not an ordinary match (a disabled first menu line and the tooltip).
    public static func whyText(_ row: ArrangeRow) -> String? {
        switch row.barState {
        case .cannotPlace(let r)?: return r
        case .staleFrame?, .behindChevron?, .unreadAfterHandDrag?, .notOnBar?, .notConfirmed?: return row.stateNote ?? row.barState?.text
        case .moving?: return row.moveReason
        case .matches?, nil: return nil
        }
    }

    /// gdu.113: a running ghost (listed Visible, not on the bar: hidden in Control Center or still arriving) can be dragged to another section and gets the section-move menu; its own drop inside Visible is a show request (gdu.110).
    public static func ghostInteractive(_ row: ArrangeRow) -> Bool {
        row.isGhost && !row.notRunning && row.draggable && !row.isAnchor
    }
}
