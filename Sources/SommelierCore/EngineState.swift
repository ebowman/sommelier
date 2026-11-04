import Foundation
import Observation

public enum ItemStatus: Equatable, Sendable {
    case inPlace
    case pending
    case moving
    case failed(ActuationError)
    case unsupported(String)
}

public enum EngineError: Equatable, Sendable {
    case permissionDenied
    case observe(String)
    case conflictingManager(String)
    /// A pass was aborted after this many consecutive failed actuator calls. Cleared only by `clearFailures`/`setLayout`.
    case stoppedAfterFailures(Int)
}

/// What the UI binds to. `observed` only ever holds observed truth (a verified actuator snapshot or a fresh observe),
/// never an optimistic guess. Written by `LayoutEngine` only.
@MainActor @Observable
public final class EngineState {
    public var observed: ObservedOrder
    public var layout: Layout
    public var showHiddenSection: Bool
    public var inFlight: PlannedAction?
    public var perItem: [ItemKey: ItemStatus]
    public var lastError: EngineError?
    public var isConverged: Bool
    public var lastPassAt: Date?
    public var passCount: Int

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
