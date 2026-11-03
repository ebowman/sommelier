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
