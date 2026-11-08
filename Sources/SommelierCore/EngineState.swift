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
    /// gdu.105: the planner refused the move because the subject's on-bar position was not corroborated by this scan (gdu.94);
    /// transient: the engine re-plans soon and the Arrange tracker keeps waiting. Never struck, never a failure.
    case waitingForPosition(String)
    /// macOS moved it into its own overflow (behind the chevron): reported on the bar but not drawn, so it cannot be
    /// dragged. Otherwise in place (gdu.45).
    case notFitting
    /// 9o9.4: the engine gave up on this key after `attempts` order moves within the attempt window; it keeps its observed slot and
    /// is excluded from planning until Retry, a new drop of it in Arrange, its app relaunching, or Sommelier relaunching.
    case cannotPlace(reason: String, attempts: Int)
}

/// 9o9.5: what the engine's last plan decided, published after every pass so Arrange DISPLAYS the plan instead of re-deriving it.
public struct PlanSummary: Equatable, Sendable {
    /// Subjects of every action in the last plan (including the ones the one-move-at-a-time cap defers).
    public var moving: Set<ItemKey> = []
    /// Keys the planner would move but cannot spell safely: subject -> the untrusted / unsteady key ("wall") in the way.
    public var blocked: [ItemKey: ItemKey] = [:]
    /// The engine's held set: given up on (cannotPlace) or unverified after a hand drag or failed at the strike limit. Out of the record
    /// for planning purposes; Arrange leaves them out when judging whether a neighbour sits where the record says.
    public var held: Set<ItemKey> = []
    /// 9o9.5: trusted keys blocked because none of their candidate moves lands safely, with no untrusted key to name as the wall.
    public var blockedNoWall: Set<ItemKey> = []
    /// 9o9.5: `passesStarted` of the pass that PUBLISHED this plan (0 = never). A drop is handed over to this plan only when it was
    /// published by a pass that started after the drop; a busy-skipped pass publishes no plan and so never counts.
    public var passStarted: Int = 0
    /// gdu.126: fold-move subjects withheld by the bar-level strip hold, and the folded count while the hold is active.
    public var stripHeld: Set<ItemKey> = []
    public var stripHoldFolded: Int?
    public var stripHoldUnplaceable = false
    public init(moving: Set<ItemKey> = [], blocked: [ItemKey: ItemKey] = [:], held: Set<ItemKey> = [], blockedNoWall: Set<ItemKey> = [], passStarted: Int = 0) {
        self.moving = moving; self.blocked = blocked; self.held = held; self.blockedNoWall = blockedNoWall; self.passStarted = passStarted
    }
    public init(plan: Plan, held: Set<ItemKey>) {
        self.init(moving: Set(plan.actions.map { a -> ItemKey in switch a { case .move(let k, _), .hide(let k), .show(let k): return k } }),
                  blocked: plan.blockedBy, held: held, blockedNoWall: plan.blockedNoWall)
        stripHeld = plan.stripHeld; stripHoldFolded = plan.stripHoldFolded; stripHoldUnplaceable = plan.stripHoldUnplaceable
    }
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
    /// 9o9.3: a complete, settled observation with fresh frames exists (what a drop made during the pending upgrade adoption adopts first).
    public var cleanObservationAvailable: Bool = false
    public var inFlight: PlannedAction?
    /// 9o9.5: the partition of the engine's last plan; replaced by every pass that planned.
    public var lastPlan: PlanSummary = PlanSummary()
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
    /// 9o9.7: "Adopted your menu bar drag" for the Arrange status line after a hand Command-drag became the record (cleared after a few seconds).
    public var handDragNotice: String?
    /// 9o9.25: "Moved X to Hidden: it is hidden in System Settings" after a Control Center hide was adopted into the record (cleared after 10 s).
    public var systemSettingsNotice: String?
    /// 9o9.5: keys the user moved by hand in the menu bar whose new position is still unread (stale or ambiguous): held out of planning
    /// by the engine, shown by Arrange as "Moved by you in the menu bar; waiting to read its new position". Never a check.
    public var unverifiedAfterHandDrag: Set<ItemKey> = []
    /// gdu.80: set by a reveal pass on a full bar whose layout order differs from the bar: membership was applied, the order was
    /// not (macOS decides what fits). Cleared at the start of every pass.
    public var orderNotAppliedNotice: String?
    /// gdu.89: why the move in flight happens ("Moving X: you placed it after Y"); set before each planned drag, cleared when the order
    /// phase ends and at the start of every pass. `orderMoveReasons` is the same text per moving key (the row badge tooltip).
    public var orderMoveNotice: String?
    public var orderMoveReasons: [ItemKey: String] = [:]
    /// gdu.78: set when the retries of units left unsettled (stale member) ran out; cleared when they apply or a trigger restarts the back-off.
    public var unsettledNotice: String?
    /// Keys the engine moved to `visible` when it adopted the last layout (`start`, `setLayout`) because their app also had a
    /// visible item: hide units are all-or-nothing (gdu.44). Empty when nothing was moved. Replaced by every adoption, so the
    /// Arrange status line can show "N items moved to Visible with their app" for the latest layout only.
    public var lastNormalization: [ItemKey] = []
    /// Set while the poll is suppressed because of a flapping item (gdu.58); status line only, never an error.
    public var pollSuppression: PollSuppression?
    /// 9o9.4: the user chose "Pause Sommelier": observation continues, no actuator call is made. Never persisted.
    public var userPaused: Bool = false
    /// 9o9.4: the per-minute order-move cap is active until this time (order phase skipped, membership still runs); nil when not capped.
    public var orderCapUntil: Date?
    /// 9o9.4: why the last pass ended without actuating (a menu open, the mouse down, a modifier held, an Arrange drag, a locked screen);
    /// nil once a pass is allowed to actuate again.
    public var pauseReason: String?

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

/// gdu.89: wording of the "why is this item being dragged" notice. Every planned move exists because the user placed that item.
public enum OrderMoveNotice {
    public static func text(name: String, relation: Relation, target: String?) -> String {
        let why: String
        switch relation {
        case .after: why = "you placed it after \(target ?? "its neighbour")"
        case .before: why = "you placed it before \(target ?? "its neighbour")"
        case .leftmost: why = "you placed it first"
        case .rightmost: why = "you placed it last"
        }
        return "Moving \(name): \(why)"
    }
}

/// 9o9.7: wording of the hand-drag notice.
public enum HandDragNotice {
    public static let text = "Adopted your menu bar drag"
}

/// 9o9.25: wording of the System Settings adoption notice.
public enum SystemSettingsNotice {
    public static func text(_ names: [String]) -> String {
        names.count == 1 ? "Moved \(names[0]) to Hidden: it is hidden in System Settings"
                         : "Moved \(names.joined(separator: ", ")) to Hidden: they are hidden in System Settings"
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
