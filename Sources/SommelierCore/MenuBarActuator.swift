import Foundation

/// Where to put a moved item, in terms of other items' keys (never coordinates).
public enum Relation: Equatable, Sendable {
    case before(ItemKey)
    case after(ItemKey)
    /// Leftmost / rightmost movable slot of the on-bar section (modules and clock stay right of `rightmost`).
    case leftmost
    case rightmost
}

public enum ActuationError: Error, Equatable, Sendable {
    case notFound
    case unsupportedItem(reason: String)
    /// The action ran but the final full scan disagrees with the expectation.
    case notVerified(expected: String, observed: String)
    case timeout
    case permissionDenied
    /// The human is using the mouse (drags) or another actuation is in flight.
    case userBusy
    case mechanismFailed(String)
    /// A competing menu bar manager is running (e.g. "Bartender 7 is running"); nothing was touched.
    case conflictingManager(String)
    /// The live `isAllowed` write itself failed (no entitlement, the write threw, or the readback never showed the intended
    /// value) and a MenuBarAgent restart is not allowed (gdu.55). Not a verification failure: nothing was respawned.
    case liveWriteFailed(String)
    /// An unrequested member of the unit's Control Center entry is STALE (its state unknown), so flipping the entry could change
    /// it silently. TRANSIENT (gdu.76): not a capability refusal, never in `lastBatchRefused`, never struck; the next pass retries.
    case memberStale(String)
}

extension ActuationError {
    /// gdu.126: the message of a failed strip open. A BAR-level failure: the engine holds every fold move for the current bar state.
    public static let stripOpenFailureMessage = "could not open the « strip"
    public var isStripOpenFailure: Bool {
        if case .mechanismFailed(let m) = self { return m == Self.stripOpenFailureMessage }
        return false
    }
    /// gdu.129: the strip opened (we opened it) but the fresh open-strip scan could not pin the subject down: no drag was posted. Also a
    /// BAR-level outcome, held exactly like a failed open.
    public static let stripUnplaceableMessage = "the « strip opened but the item could not be pinned down inside it"
    public var isStripUnplaceable: Bool {
        if case .mechanismFailed(let m) = self { return m == Self.stripUnplaceableMessage }
        return false
    }
    /// gdu.134: a drag across the fold was posted inside a strip session we opened and did not verify (or the menu bar moved the item back).
    /// Also BAR-level: at most one fold-crossing drag per bar state.
    public static let stripMoveDidNotHoldMessage = "a move across the fold did not hold"
    public var isStripMoveDidNotHold: Bool {
        if case .mechanismFailed(let m) = self { return m == Self.stripMoveDidNotHoldMessage }
        return false
    }
    /// gdu.126 / gdu.129 / gdu.134: any bar-level strip failure (open failed, opened but unplaceable, or a cross-fold move did not hold).
    public var isStripHoldFailure: Bool { isStripOpenFailure || isStripUnplaceable || isStripMoveDidNotHold }
    /// Text carried by the actuator's refusal to drag an item (or anchor) that sits in macOS's overflow area (gdu.25, gdu.69).
    public static let overflowRefusalMarker = "is in the menu bar overflow area"
    /// The actuator refused BEFORE any drag because the subject or relation anchor is in macOS's overflow area. Not a failure
    /// of the item: the engine treats it as a skip and never strikes the key.
    public var isOverflowRefusal: Bool {
        if case .mechanismFailed(let m) = self { return m.contains(Self.overflowRefusalMarker) }
        return false
    }
}

/// Outcome of an actuation. `.verified` is only returned after a settled full scan satisfied the predicate.
public enum ActuationResult: Sendable {
    case verified(MenuBarSnapshot)
    /// The snapshot is the last observation (nil when no scan was possible, e.g. permission denied).
    case failed(ActuationError, MenuBarSnapshot?)

    public var isVerified: Bool { if case .verified = self { return true } else { return false } }
    public var error: ActuationError? { if case .failed(let e, _) = self { return e } else { return nil } }
}

/// The only way the UI changes the menu bar. Every call is closed-loop (see docs/architecture.md).
public protocol MenuBarActuator: Sendable {
    func move(_ key: ItemKey, relation: Relation) async -> ActuationResult
    func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult
    /// All changes applied with ONE agent restart. Verification is per key; the result is `.verified` only if every key
    /// verifies, otherwise `.failed(.notVerified(...))` carrying the full snapshot.
    func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult
    /// True when the last batch went through an agent respawn (see the extension default).
    var lastBatchRespawned: Bool { get async }
    /// Keys of the last batch that were APPLIED per the Control Center store but whose result no complete read has confirmed
    /// yet (`ActuationMechanism.liveUnverified`, gdu.55). The engine shows them in place with a pending-confirmation marker.
    var lastBatchUnconfirmed: Set<ItemKey> { get async }
    /// Units of the last batch refused BEFORE the write because they cannot be hidden/shown (not tracked, Apple app...), with
    /// the capability's reason (gdu.72). The rest of the batch was applied; the aggregate result covers only the applied units
    /// (all refused: `.failed(.unsupportedItem)`). The engine treats these as skips, never strikes.
    var lastBatchRefused: [ItemKey: String] { get async }
    /// Units of the last batch left alone because a member's state was unknown (`ActuationError.memberStale`, gdu.76), with the
    /// reason. Transient: the engine keeps them pending, records no refusal and no strike, and the next pass tries again.
    var lastBatchUnsettled: [ItemKey: String] { get async }
    /// gdu.80: the churn zone (`SystemOverflowRule.churnZone`) the engine computed from its last two complete reads. A move whose
    /// subject or relation anchor is in it is not dragged on the collapsed bar (9o9.12: it is performed inside a strip session, like
    /// a move across the fold).
    func setChurnZone(_ keys: Set<ItemKey>) async
    /// 9o9.19: the Visible record's full order (`Layout.visible`), handed over right before a move like the churn zone. A crossing is
    /// verified by the fold rule against it (the fold is a prefix of the record) instead of adjacency to a target that may re-fold
    /// into the pile. Empty = unknown: adjacency only.
    func setRecordOrder(_ keys: [ItemKey]) async
}

public extension MenuBarActuator {
    func setChurnZone(_ keys: Set<ItemKey>) async {}
    func setRecordOrder(_ keys: [ItemKey]) async {}
    /// True when the last `applyHiddenBatch` ended in (or went through) an agent respawn (the fallback path). Default: never.
    var lastBatchRespawned: Bool { get async { false } }
    var lastBatchUnconfirmed: Set<ItemKey> { get async { [] } }
    var lastBatchRefused: [ItemKey: String] { get async { [:] } }
    var lastBatchUnsettled: [ItemKey: String] { get async { [:] } }
}

/// What may be done to one item on this OS; the UI greys out controls and shows `reason`.
public struct Capability: Equatable, Sendable {
    public var canMove: Bool
    public var canHide: Bool
    public var reason: String?
    public init(canMove: Bool, canHide: Bool, reason: String? = nil) {
        self.canMove = canMove
        self.canHide = canHide
        self.reason = reason
    }
}

public protocol CapabilityProvider: Sendable {
    func capability(for key: ItemKey) -> Capability
}

/// Capability rules derived from docs/findings-{drag,visibility,positioning}.md.
public struct CapabilityRules: CapabilityProvider {
    /// True when Control Center's `trackedApplications` has an entry for this item's app.
    public var hasTrackedEntry: @Sendable (ItemKey) -> Bool

    public init(hasTrackedEntry: @escaping @Sendable (ItemKey) -> Bool) { self.hasTrackedEntry = hasTrackedEntry }

    public func capability(for key: ItemKey) -> Capability {
        switch key {
        case .module(let name):
            return Capability(canMove: false, canHide: false,
                              reason: "\(name) is a system module: it cannot be moved past Control Center/clock and is hidden only in System Settings > Menu Bar.")
        case .status(let owner, _):
            if owner.hasPrefix("com.apple.") {
                return Capability(canMove: true, canHide: false, reason: "Apple apps are hidden only in System Settings > Menu Bar.")
            }
            guard hasTrackedEntry(key) else {
                return Capability(canMove: true, canHide: false,
                                  reason: "macOS has no Control Center entry for this app yet, so it cannot be hidden.")
            }
            return Capability(canMove: true, canHide: true)
        case .heuristic:
            let hide = hasTrackedEntry(key)
            return Capability(canMove: true, canHide: hide,
                              reason: hide ? "Identity is a guess; results are verified more cautiously."
                                           : "Identity is a guess and no Control Center entry is known, so it cannot be hidden.")
        }
    }
}
