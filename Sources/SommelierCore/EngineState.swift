import Foundation
import Observation

/// What `LayoutEngine.setLayout` returns: the revision the call produced and `passesStarted` when it was published.
public struct LayoutRevision: Equatable, Sendable {
    public var revision: Int
    public var passesStarted: Int
    public init(revision: Int, passesStarted: Int) { self.revision = revision; self.passesStarted = passesStarted }
}

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
    /// A membership batch failed for a reason other than drift (e.g. `.mechanismFailed`). Sticky like `batchDrift`:
    /// observing does not clear it; only `clearFailures`/`setLayout` do.
    case batchFailed(String)
}

/// What the UI binds to. `observed` only ever holds observed truth (a verified actuator snapshot or a fresh observe),
/// never an optimistic guess. Written by `LayoutEngine` only.
@MainActor @Observable
public final class EngineState {
    public var observed: ObservedOrder
    public var layout: Layout
    /// Display metadata for currently known items (parked or on bar), refreshed with every adopted scan.
    public var items: [ItemKey: ItemInfo] = [:]
    /// The engine's hide-unit rule (gdu.75) for the items above: Arrange and the overflow panel group with it, as the planner does.
    public var hideUnits: HideUnitRule = .ownerKeys
    public var showHiddenSection: Bool
    /// Requested reveal of the always-hidden section too (option-click). Request only, like `showHiddenSection`.
    public var showAlwaysHidden: Bool = false
    /// OBSERVED reveal state (never optimistic): written only when a pass ends (converged or incomplete) from the bar it
    /// observed. True when a reveal is requested and at least one item of the revealed sections is on the bar (a partial
    /// reveal counts as shown; failed items carry their own `perItem` status); with no reveal requested, true while a
    /// hidden-listed item (not failed/unsupported) is still on the bar, i.e. until the re-hide has landed.
    public var revealedObserved: Bool = false
    /// Arrange status-line text after a reveal was refused or withdrawn ("Reveal withdrawn: N items could not be shown"); cleared by the next reveal click.
    public var revealNotice: String?
    public var inFlight: PlannedAction?
    public var perItem: [ItemKey: ItemStatus]
    /// Keys that are `.inPlace` because a live hide/show was APPLIED per the Control Center store, but no usable complete read
    /// has confirmed it yet (`ActuationMechanism.liveUnverified`, gdu.55). Cleared by a later settled complete read.
    public var pendingConfirmation: Set<ItemKey> = []
    public var lastError: EngineError?
    public var isConverged: Bool
    public var lastPassAt: Date?
    /// gdu.71: how long the latest pass's pre-write observation took (ms) and whether it reused the adopted observation as its first scan.
    public var lastObserveMillis: Int?
    public var lastObserveReused = false
    public var passCount: Int
    /// Passes started / finished, monotonically increasing; passes run one at a time, so the pass that started right after
    /// a UI action has finished exactly when `passSequence > passesStarted-at-that-moment` (the Arrange window judges a drop
    /// only by such a pass; a pass already in flight when the action happened never counts).
    public var passesStarted: Int = 0
    public var passSequence: Int = 0
    /// False while `observed` is the latest complete read that two scans did not agree on (gdu.46): shown, never acted on.
    public var observationSettled: Bool = true
    /// Monotonic layout revision (gdu.48): incremented every time the engine adopts a layout (`start`, `setLayout`) or modifies
    /// it itself (new items appended). `passesStartedAtRevision` is `passesStarted` at the moment that revision was published:
    /// a pass judges a layout change only if `passSequence > passesStartedAtRevision` (it then started after publication).
    public var layoutRevision: Int = 0
    public var passesStartedAtRevision: Int = 0
    /// Transient "New item: X placed in Visible" text for the Arrange window status line (cleared by the engine after a few seconds).
    public var newItemNotice: String?
    /// gdu.80: set by a reveal pass on a full bar whose layout order differs from the bar: membership was applied, the order was
    /// not (macOS decides what fits). Cleared at the start of every pass.
    public var orderNotAppliedNotice: String?
    /// Keys the engine moved to `visible` when it adopted the last layout (`start`, `setLayout`) because their app also had a
    /// visible item: hide units are all-or-nothing (gdu.44). Empty when nothing was moved. Replaced by every adoption, so the
    /// Arrange status line can show "N items moved to Visible with their app" for the latest layout only.
    /// Set while the poll is suppressed because of a flapping item (gdu.58); status line only, never an error.
    public var pollSuppression: PollSuppression?
    public var lastNormalization: [ItemKey] = []

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
