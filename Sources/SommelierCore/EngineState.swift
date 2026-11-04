import Foundation
import Observation

public enum ItemStatus: Equatable, Sendable {
    case inPlace
    case pending
    case moving
    case failed(ActuationError)
    case unsupported(String)
    /// macOS moved it into its own overflow (behind the chevron): reported on the bar but not drawn, so it cannot be
    /// dragged. Otherwise in place (gdu.45).
    case notFitting
}

public enum EngineError: Equatable, Sendable {
    case permissionDenied
    case observe(String)
    case conflictingManager(String)
    /// A pass was aborted after this many consecutive failed actuator calls. Cleared only by `clearFailures`/`setLayout`.
    case stoppedAfterFailures(Int)
    /// A membership batch reported it could not verify the result (e.g. a non-batch item moved across the agent
    /// restart). Not cleared by observing; cleared only by `clearFailures`/`setLayout`.
    case batchDrift(expected: String, observed: String)
}

/// What the UI binds to. `observed` only ever holds observed truth (a verified actuator snapshot or a fresh observe),
/// never an optimistic guess. Written by `LayoutEngine` only.
@MainActor @Observable
public final class EngineState {
    public var observed: ObservedOrder
    public var layout: Layout
    /// Display metadata for currently known items (parked or on bar), refreshed with every adopted scan.
    public var items: [ItemKey: ItemInfo] = [:]
    public var showHiddenSection: Bool
    public var inFlight: PlannedAction?
    public var perItem: [ItemKey: ItemStatus]
    public var lastError: EngineError?
    public var isConverged: Bool
    public var lastPassAt: Date?
    public var passCount: Int
    /// Passes started / finished, monotonically increasing; passes run one at a time, so the pass that started right after
    /// a UI action has finished exactly when `passSequence > passesStarted-at-that-moment` (the Arrange window judges a drop
    /// only by such a pass; a pass already in flight when the action happened never counts).
    public var passesStarted: Int = 0
    public var passSequence: Int = 0
    /// False while `observed` is the latest complete read that two scans did not agree on (gdu.46): shown, never acted on.
    public var observationSettled: Bool = true
    /// Transient "New item: X placed in Visible" text for the Arrange window status line (cleared by the engine after a few seconds).
    public var newItemNotice: String?

    public init(observed: ObservedOrder = ObservedOrder(onBar: [], parked: []), layout: Layout = .empty,
                showHiddenSection: Bool = false) {
        self.observed = observed
        self.layout = layout
        self.showHiddenSection = showHiddenSection
        self.inFlight = nil
        self.perItem = [:]
        self.lastError = nil
        self.isConverged = false
        self.lastPassAt = nil
        self.passCount = 0
    }
}

/// Wording of the transient new-item notice.
public enum NewItemNotice {
    public static let lifetime: Duration = .seconds(10)

    /// "New item: A placed in Visible" / "New items: A, B placed in Visible; C placed in Hidden"; nil when empty.
    public static func text(_ items: [(name: String, section: LayoutSection)]) -> String? {
        guard !items.isEmpty else { return nil }
        func label(_ s: LayoutSection) -> String {
            switch s { case .visible: return "Visible"; case .hidden: return "Hidden"; case .alwaysHidden: return "Always hidden" }
        }
        var order: [LayoutSection] = []
        for i in items where !order.contains(i.section) { order.append(i.section) }
        let parts = order.map { sec in "\(items.filter { $0.section == sec }.map(\.name).joined(separator: ", ")) placed in \(label(sec))" }
        return (items.count == 1 ? "New item: " : "New items: ") + parts.joined(separator: "; ")
    }
}
