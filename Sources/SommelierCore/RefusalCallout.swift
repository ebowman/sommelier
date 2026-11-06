import Foundation

/// UI-only state for a refused Arrange drop: the reason is shown for `duration` seconds in a callout at the dragged capsule.
/// Never persisted and never sent to the engine.
public struct RefusalCallout: Equatable, Sendable {
    /// Capsule to anchor at: the dragged key.
    public var key: ItemKey
    /// The refusal reason, verbatim.
    public var text: String
    public var shownAt: Date
    /// Increments per refusal; drives the shake animation trigger.
    public var serial: Int
    public static let duration: TimeInterval = 3

    public init(key: ItemKey, text: String, shownAt: Date, serial: Int) {
        self.key = key; self.text = text; self.shownAt = shownAt; self.serial = serial
    }

    public func isActive(at now: Date) -> Bool { now < shownAt.addingTimeInterval(Self.duration) }

    /// nil when the dragged key has no non-ghost capsule among `rows` (filtered out / not rendered): then only the message line shows.
    public static func anchor(for key: ItemKey, in rows: [ArrangeRow]) -> ItemKey? {
        rows.contains { $0.key == key && !$0.isGhost } ? key : nil
    }

    /// Replaces `current` (any key) with a new callout for `key`; serial = (current?.serial ?? 0) + 1.
    public static func show(_ current: RefusalCallout?, key: ItemKey, why: String, now: Date) -> RefusalCallout {
        RefusalCallout(key: key, text: why, shownAt: now, serial: (current?.serial ?? 0) + 1)
    }
}
