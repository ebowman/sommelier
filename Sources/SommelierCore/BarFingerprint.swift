import Foundation

/// gdu.126: what "the same bar state" means for the strip hold (`LayoutEngine.stripOpenHold`): whether the chevron is on the bar, how many
/// items are drawn, and which are folded behind « (the system-overflow pile plus the items macOS folds for width). Any change releases the
/// hold, so a changed bar earns exactly one more chevron click.
public struct BarFingerprint: Equatable, Sendable {
    public var hasChevron: Bool
    public var drawn: Int
    public var folded: Set<ItemKey>

    public init(hasChevron: Bool, drawn: Int, folded: Set<ItemKey>) {
        self.hasChevron = hasChevron; self.drawn = drawn; self.folded = folded
    }

    public init(_ o: ObservedOrder) {
        self.init(hasChevron: o.overflowChevron != nil,
                  drawn: o.onBar.filter { !o.systemOverflow.contains($0) && $0 != o.overflowChevron && !$0.isOverflowChevron }.count,
                  folded: o.systemOverflow.union(o.foldedParked))
    }
}
