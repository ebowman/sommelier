import CoreGraphics
import Foundation

/// gdu.126: THE rule for "MenuBarAgent's « strip is expanded". One definition shared by `LiveAccessibilitySource.overflowProbe` (the
/// actuator and `StripController`) and `MenuBarScanner` (`MenuBarItem.stripExpanded`, so the planner and the verifier read the same truth).
/// Any ONE clause is enough (the order below is the order they are tried and the name logged):
///
/// 1. `description`: the chevron's AX description is "Hide Menu Bar Items" (`MenuBarItem.overflowChevronOpenName`) instead of "Show Hidden
///    Menu Bar Items". Seen live on the 644 pt portrait display (2026-11-08): collapsed -> "Show Hidden Menu Bar Items", expanded ->
///    "Hide Menu Bar Items", the chevron's frame unchanged (x 453, w 18).
/// 2. `geometric`: the agent's AXMenuBar starts LEFT of the chevron (`stripMinX < chevron.minX - 2`). The original 9o9.11 / gdu.65 rule;
///    it fires on the wide display. On the narrow one the AXMenuBar minX never moves left of the chevron, so it stays silent there.
/// 3. `deStacked`: at least two hosted frames left of the chevron that do not overlap one another and span at least 60 pt. Collapsed, the
///    pile is STACKED (live: x 405/63, 427/41, 443/24, 443/24, 444/24, 447/24 overlapping, right behind the chevron at 453); expanded the
///    same elements are laid out at distinct real frames (x 141/51, 197/24, 226/41, 302/24, 331/24, 356/24, 381/63: 141...444 = 303 pt).
public enum StripExpansionRule {
    public enum Clause: String, Equatable, Sendable { case description, geometric, deStacked }

    /// Minimum union width of the de-stacked frames (clause 3).
    public static let minDeStackedWidth: CGFloat = 60

    /// The clause that says the strip is open, nil when none does (or the bar has no chevron).
    public static func clause(chevron: CGRect?, chevronDescription: String?, stripMinX: CGFloat?, hosted: [CGRect]) -> Clause? {
        guard let c = chevron else { return nil }
        if chevronDescription == MenuBarItem.overflowChevronOpenName { return .description }
        if let m = stripMinX, m < c.minX - 2 { return .geometric }
        if deStacked(hosted: hosted, chevron: c) { return .deStacked }
        return nil
    }

    static func deStacked(hosted: [CGRect], chevron: CGRect) -> Bool {
        let left = hosted.filter { $0.width > 1 && $0.minX < chevron.minX }.sorted { $0.minX < $1.minX }
        guard left.count >= 2 else { return false }
        for (a, b) in zip(left, left.dropFirst()) where b.minX < a.maxX - 0.5 { return false }   // any overlap: still stacked
        guard let lo = left.first?.minX, let hi = left.map(\.maxX).max() else { return false }
        return hi - lo >= minDeStackedWidth
    }
}
