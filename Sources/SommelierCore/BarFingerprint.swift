import Foundation

/// gdu.126/gdu.131: what "the same bar state" means for the strip hold (`LayoutEngine.stripOpenHold`): whether the chevron is on the bar and
/// how many items are drawn. The folded SET is deliberately not part of it: it flaps between reads (stale and fresh iStat items), while the
/// chevron and the drawn count do not. A change releases the hold only when seen on two consecutive observations.
public struct BarFingerprint: Equatable, Sendable {
    public var hasChevron: Bool
    public var drawn: Int

    public init(hasChevron: Bool, drawn: Int) {
        self.hasChevron = hasChevron; self.drawn = drawn
    }

    public init(_ o: ObservedOrder) {
        self.init(hasChevron: o.overflowChevron != nil || o.chevronRecent,
                  drawn: o.onBar.filter { !o.systemOverflow.contains($0) && $0 != o.overflowChevron && !$0.isOverflowChevron }.count)
    }

    /// The folded keys of an observation (the system-overflow pile plus the items macOS folds for width): the status line's N and the
    /// keys a held fold move may involve. Not part of the fingerprint's equality.
    public static func folded(_ o: ObservedOrder) -> Set<ItemKey> { o.systemOverflow.union(o.foldedParked) }
}
