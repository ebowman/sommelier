import Foundation
import DecisionCore

// Pure model behind the Arrange window (gdu.19). No AppKit, no engine calls: everything here maps values to values so
// the truthfulness rules are unit-testable. The app target (ArrangeViewModel) only feeds it state and submits the result.

/// What the status badge on a capsule says. Rule: a badge is `.inPlace` only when the ENGINE says so for an item whose
/// observed position matches the layout; everything else is shown for what it is.
public enum ArrangeBadge: Equatable, Sendable {
    /// No claim (app not running, or no observation yet).
    case none
    case inPlace
    /// Applied per the Control Center store, but no complete read has confirmed it yet (gdu.55): a check mark with a marker.
    case inPlacePending
    /// Pending, moving, or waiting for the next observation to place it.
    case moving
    case failed(String)
    /// Cannot be moved or hidden here (capabilities, or the engine skipped it with this reason).
    case cannotChange(String)
    /// macOS moved it into its own overflow behind the chevron: reported on the bar but not drawn (gdu.45).
    case notFitting
    /// gdu.101: on the bar but its position was not refreshed (the app has not answered a position read); shown at the last-known slot.
    case stale
    /// gdu.105: the move is waiting for a scan that corroborates the item's position (transient; the engine re-plans).
    case waitingForPosition
    /// 9o9.5: a Visible record key that is not on the bar (hidden in Control Center, or its app not drawing it yet): shown at its record slot.
    case ghost
    /// 9o9.5: the engine cannot place this key (failed, unsupported, gave up): the row's text is the reason.
    case cannotPlace(String)
    /// 9o9.5: macOS hides it behind the « chevron because the bar is full.
    case behindChevron
    /// 9o9.5: the user moved it by hand in the menu bar and its new position is not read yet.
    case unreadAfterHandDrag

    public var glyph: String {
        switch self {
        case .none: return ""
        case .inPlace: return "✓"
        case .inPlacePending: return "✓"
        case .moving: return "⟳"
        case .failed: return "⚠"
        case .cannotChange: return "⊘"
        case .notFitting: return "⇠"
        case .stale: return "~"
        case .waitingForPosition: return "⟳"
        case .ghost: return "◌"
        case .cannotPlace: return "⚠"
        case .behindChevron: return "«"
        case .unreadAfterHandDrag: return "⏳"
        }
    }

    public var tooltip: String {
        switch self {
        case .none: return ""
        case .inPlace: return "In place (verified against the real menu bar)"
        case .inPlacePending: return "Applied; confirmation pending (the menu bar could not be read completely yet)"
        case .moving: return "Waiting for the menu bar to change"
        case .failed(let e): return "Failed: \(e)"
        case .cannotChange(let r): return r
        case .notFitting: return "Does not fit: macOS moved it into its overflow behind the chevron"
        case .waitingForPosition: return "Waiting for a trustworthy read of its position (the last scan could not corroborate where it is)"
        case .stale: return ArrangeBarState.staleText
        case .ghost: return ArrangeBarState.notOnBarText
        case .cannotPlace(let r): return r
        case .behindChevron: return ArrangeBarState.behindChevronText
        case .unreadAfterHandDrag: return ArrangeBarState.unreadAfterHandDragText
        }
    }
}

/// 9o9.5: how the real menu bar stands against one Visible record row. The strip is the RECORD in record order; this is the only
/// claim a row makes about the bar. `.matches` (the check) needs `placementMatches` and no hold, hand-drag doubt, skip or failure.
public enum ArrangeBarState: Equatable, Sendable {
    /// The bar agrees with the record for this row.
    case matches
    /// The engine will move it (pending, in flight, planned) or the bar does not agree yet.
    case moving
    /// The engine failed, skipped it as unsupported, or gave up (the plain-words reason).
    case cannotPlace(String)
    /// Not on the bar (ghost at its record slot).
    case notOnBar
    /// On the bar but its position is being re-read (stale or waiting for a corroborated read).
    case staleFrame
    /// macOS hides it behind the « chevron and the fold agrees with the record.
    case behindChevron
    /// The user moved it by hand; its new position is not read yet.
    case unreadAfterHandDrag
    /// Drawn, and the engine plans nothing for it, but its observed neighbours are not the record's: no claim either way (never a check).
    case notConfirmed

    public static let staleText = "Position being re-read"
    public static let notOnBarText = "Not on the menu bar right now: this is where it is going, not where it is."
    public static let behindChevronText = "Behind «: macOS hides it because the bar is full. Drag it right of the fold line to bring it out."
    /// gdu.126: the note of a fold move the engine holds because the « strip would not open.
    public static let unreadAfterHandDragText = "Moved by you in the menu bar; waiting to read its new position"
    public static let matchesText = "In place (verified against the real menu bar)"
    public static let movingText = "Waiting for the menu bar to change"
    public static let notConfirmedText = "Not confirmed in place yet"
    /// gdu.144 rule 5: the status-line warning for a Visible drop left of the fold line; also the row note of that key. macOS folds from the left.
    public static func stayBehindText(_ name: String) -> String { "\(name) is in your order, but macOS folds from the left, so it stays behind « until there is room" }
    /// gdu.144 D6: a DRAWN key dropped left of the fold line: the record takes it, the key goes as far left as the drawn items go.
    public static func cannotGoFurtherLeftText(_ name: String) -> String { "\(name) is in your order, but macOS folds from the left, so it can't go further left until there is room" }
    /// gdu.144 D7: a drawn row on a chevron bar whose drawn order differs from the record (never a check).
    public static let differsFromYourOrderText = "differs from your order"
    /// gdu.144 D8: moves were withheld (gate / hold / spent budget) while the bar differs from the record.
    public static let stoppedWhileDifferingText = "Your order and the bar differ. Sommelier has stopped moving items on its own: drag an item or press Re-apply layout."
    /// gdu.144 rule 5: a folded key the user dropped right of the fold line was put back behind « by macOS.
    public static let putBackText = "macOS put it back behind «; hide something to make room"

    public var text: String {
        switch self {
        case .matches: return Self.matchesText
        case .moving: return Self.movingText
        case .cannotPlace(let r): return r
        case .notOnBar: return Self.notOnBarText
        case .staleFrame: return Self.staleText
        case .behindChevron: return Self.behindChevronText
        case .unreadAfterHandDrag: return Self.unreadAfterHandDragText
        case .notConfirmed: return Self.notConfirmedText
        }
    }
}

public struct ArrangeRow: Identifiable, Equatable, Sendable {
    public var key: ItemKey
    public var title: String
    public var ownerName: String
    public var ownerBundleID: String?
    public var ownerPID: pid_t?
    public var badge: ArrangeBadge
    /// Can be picked up (capability canMove). Anchors (system modules) are never draggable.
    public var draggable: Bool
    public var canHide: Bool
    /// Fixed system item shown so the Visible strip matches the real bar.
    public var isAnchor: Bool
    /// Shown at the target slot of a pending move; the real capsule is still where the bar has it.
    public var isGhost: Bool
    /// The macOS overflow chevron: rendered as the overflow boundary line, never as a capsule.
    public var isBoundary: Bool
    /// Reported on the bar but not drawn (left of the chevron).
    public var notFitting: Bool
    public var notRunning: Bool
    public var unit: HideUnit
    /// Titles of the other layout keys of this hide unit ("hides together with ...").
    public var unitMates: [String]
    /// Display name of the app whose Control Center entry governs this unit (gdu.76); nil when unknown or not a tracked unit.
    public var unitApp: String? = nil
    /// gdu.89: why this item is being dragged right now ("Moving X: you placed it after Y"); only set while its badge is `.moving`.
    public var moveReason: String? = nil
    /// gdu.101: on the bar, shown at its last-known slot because the app has not answered a position read. Still draggable (9o9.5);
    /// a drop beside it is accepted (9o9.5: the record is edited; the engine decides when it can act).
    public var staleFrame: Bool = false
    /// 9o9.5: the bar's state for this Visible row (nil for Hidden / Always hidden rows and the fold line).
    public var barState: ArrangeBarState? = nil
    /// Tooltip of the badge: the move reason replaces the generic "waiting" text while a planned drag is in flight.
    public var badgeTooltip: String { badge == .moving ? (moveReason ?? badge.tooltip) : (stateNote ?? barState?.text ?? badge.tooltip) }
    /// 9o9.5: replaces the bar state's generic text (an uncorroborated key that looks in place).
    public var stateNote: String? = nil
    /// 9o9.29: the 60 s position wait ran out for a drawn key whose observed neighbours agree with the record: it reads ~ "it looks in
    /// place" (not a warning) and offers Try again; the status line counts it as "can't be pinned down".
    public var pinDownTimedOut: Bool = false
    /// 9o9.5: display name of the untrusted key the engine's plan says this row's move waits for ("Waiting for <it> to settle").
    public var waitingOn: String? = nil
    /// Capability reason when the item cannot be moved or hidden (rendered as a small ⊘).
    public var capabilityNote: String?
    /// 9o9.24: the ⊘ beside a row's name means a CAPABILITY LIMIT (not a state of the bar): it cannot be hidden here, or cannot be moved. Said in words.
    public var capabilityTooltip: String? {
        guard let n = capabilityNote else { return nil }
        return (draggable ? "Can't be hidden by Sommelier: " : "Can't be moved: ") + n
    }
    /// 9o9.15: the raw description (else title) the app reports; the tooltip's second line and part of what Filter matches.
    public var detail: String = ""
    /// gdu.117: the sections the context menu's "Move to ..." items are enabled for (`ArrangeDrop.canMove`), computed once when the
    /// content is built instead of on every render. Empty for anchors and the fold line.
    public var movableTo: Set<LayoutSection> = []
    /// gdu.117: whether "Move left" / "Move right" are enabled (`ArrangeDrop.step` yields a move); Visible rows only.
    public var canStepLeft = false
    public var canStepRight = false
    public var id: String { isGhost ? key.description + "#ghost" : key.description }

    public var unitTooltip: String? { HideUnitNames.unitNote(mates: unitMates, app: unitApp) }
}

public struct ArrangeStrip: Equatable, Sendable {
    public var section: LayoutSection
    public var rows: [ArrangeRow]
    /// Layout items whose app is not running; rendered in a collapsed group at the end.
    public var notRunning: [ArrangeRow]
    public init(section: LayoutSection, rows: [ArrangeRow] = [], notRunning: [ArrangeRow] = []) {
        self.section = section; self.rows = rows; self.notRunning = notRunning
    }
    public var boundaryIndex: Int? { rows.firstIndex { $0.isBoundary } }
}

public struct ArrangeContent: Equatable, Sendable {
    public var visible: ArrangeStrip
    public var hidden: ArrangeStrip
    public var alwaysHidden: ArrangeStrip
    /// False until the engine has published a first observation; rows then carry no claims.
    public var observedAvailable: Bool
    /// Set instead of Visible capsules while there is no trustworthy observation of the bar: the layout is never drawn as
    /// "the real menu bar".
    public var visiblePlaceholder: String?
    public func strip(_ s: LayoutSection) -> ArrangeStrip {
        switch s { case .visible: return visible; case .hidden: return hidden; case .alwaysHidden: return alwaysHidden }
    }
}

public enum ArrangeSections {
    /// Text for a failed/unsupported engine error.
    public static func describe(_ e: ActuationError) -> String {
        switch e {
        case .notFound: return "item not found on the menu bar"
        case .unsupportedItem(let r): return r
        case .notVerified(let ex, let ob): return "not verified: expected \(ex), saw \(ob)"
        case .timeout: return "timed out"
        case .permissionDenied: return "Accessibility permission denied"
        case .userBusy: return "mouse in use; try again"
        case .mechanismFailed(let m): return m
        case .conflictingManager(let m): return m
        case .liveWriteFailed(let m): return "hide/show write failed: \(m)"
        case .memberStale(let r): return r
        }
    }

    /// Badge for one capsule (see `ArrangeBadge`). `pendingPlacement` is true for ghosts and for items whose move was
    /// requested but not yet seen on the real bar.
    public static func badge(status: ItemStatus?, running: Bool, pendingPlacement: Bool, isAnchor: Bool, timedOut: Bool = false,
                             pendingConfirmation: Bool = false) -> ArrangeBadge {
        guard running else { return .none }
        switch status {
        case .failed(let e)?: return .failed(describe(e))
        case .unsupported(let r)?: return .cannotChange(r)
        case .waitingForPosition?: return .waitingForPosition
        case .cannotPlace(let r, _)?: return .cannotPlace(plainReason(r))   // 9o9.4 / 9o9.5
        case .notFitting?: return .notFitting
        case .pending?, .moving?: return .moving
        case .inPlace?, nil: break
        }
        if timedOut { return .failed(ArrangeTracker.timeoutText) }
        if pendingPlacement { return .moving }
        if isAnchor { return .none }
        if status == nil { return .none }
        return pendingConfirmation ? .inPlacePending : .inPlace
    }

    /// True when the observed bar/parked state already realizes `key`'s layout position. Visible: the drawn keys common to
    /// layout and bar are in the same relative order. Hidden sections: the key is off the bar (or revealed on purpose).
    public static func placementMatches(_ key: ItemKey, layout: Layout, observed: ObservedOrder, showHiddenSection: Bool = false, showAlwaysHidden: Bool = false) -> Bool {
        guard let sec = layout.section(of: key) else { return true }
        switch sec {
        case .visible:
            if observed.foldedParked.contains(key) { return true }   // gdu.121: folded for width; macOS decides, nothing to realize
            guard observed.onBar.contains(key) else { return false }
            return drawnOrder(layout.visible, observed) == drawnOrder(observed.onBar, observed, within: layout.visible)   // gdu.144: the fold is macOS's decision
        case .hidden:
            return observed.parked.contains(key) || (showHiddenSection && observed.onBar.contains(key))
        case .alwaysHidden:
            return observed.parked.contains(key) || (showAlwaysHidden && observed.onBar.contains(key))
        }
    }

    /// 9o9.11 / gdu.144: the status of an on-bar key before plan actions, skips and failures are applied. What folds is macOS's decision, so the
    /// fold never makes a key pending: a folded key (pile or folded-parked) is `.notFitting`; every other key is `.inPlace`.
    public static func foldBaseStatus(_ key: ItemKey, layout: Layout, observed: ObservedOrder) -> ItemStatus {
        observed.systemOverflow.contains(key) || observed.foldedParked.contains(key) ? .notFitting : .inPlace
    }

    private static func drawnOrder(_ keys: [ItemKey], _ o: ObservedOrder, within: [ItemKey]? = nil) -> [ItemKey] {
        let bar = Set(o.onBar)
        let inLayout = within.map(Set.init)
        return keys.filter { bar.contains($0) && !o.systemOverflow.contains($0) && $0 != o.overflowChevron && (inLayout?.contains($0) ?? true) }
    }

    public static func fallbackTitle(_ key: ItemKey) -> String {
        switch key {
        case .status(let owner, let auto):
            if !auto.isEmpty { return auto }
            return owner.split(separator: ".").last.map(String.init) ?? owner
        case .module(let name):
            return name.hasPrefix("com.apple.menuextra.") ? String(name.dropFirst("com.apple.menuextra.".count)) : name
        case .heuristic(let b, let f, _):
            return f.isEmpty ? (b.split(separator: ".").last.map(String.init) ?? b) : f
        }
    }

    public static func ownerBundleID(_ key: ItemKey) -> String? {
        switch key {
        case .status(let o, _): return o
        case .heuristic(let b, _, _): return b
        case .module: return nil
        }
    }

    /// Why the bar cannot be observed right now (nil = no known problem; an empty observation is then just "scanning").
    public static func observationProblem(lastError: EngineError?) -> String? {
        switch lastError {
        case .observe(let m)?: return m
        case .permissionDenied?: return "Accessibility permission required"
        default: return nil
        }
    }

    /// 9o9.24: the one honest text for an on-bar key whose position the scan cannot corroborate (with or without a skip of its own).
    public static let uncorroboratedText = "Sommelier can't pin down where this item is on the bar"
    public static let pinnedDownTimeoutText = uncorroboratedText + " (it looks in place) — right-click to try again"
    public static let uncorroboratedTimeoutText = uncorroboratedText + " for a minute — right-click to try again"
    /// The prefix of the engine's `.unsupported` reason once the position wait has timed out (LayoutEngine.statuses).
    static let positionTimeoutPrefix = "could not corroborate its position on the bar for"

    /// Plain words for an engine reason (9o9.5): the technical wording stays in the log.
    public static func plainReason(_ raw: String) -> String {
        if raw.hasPrefix(Self.positionTimeoutPrefix) { return uncorroboratedTimeoutText }
        if raw.contains("corroborate") { return uncorroboratedText }
        if raw == Reconciler.staleSkipReason || raw.contains("not refreshed") || raw.contains("stale") {
            return ArrangeBarState.staleText
        }
        if raw == ActuationError.stripMoveDidNotHoldMessage { return ArrangeBarState.putBackText }   // gdu.144 rule 5
        if raw == Reconciler.overflowSkipReason || raw == SystemOverflowRule.churnSkipReason || raw.contains("macOS decides what fits") { return "Behind «; macOS decides what fits" }
        return raw
    }

    /// Builds the three strips. Visible is the RECORD (`layout.visible`) in record order (9o9.5): one row per key, each with a `barState`
    /// saying how the real bar stands against it; keys not on the bar are ghosts at their record slot. The fold line is drawn after the
    /// last key the observation reports as overflowed. Hidden / Always hidden follow the layout order too.
    public static func make(observed: ObservedOrder, layout: Layout, items: [ItemKey: ItemInfo], perItem: [ItemKey: ItemStatus],
                            capabilities: (ItemKey) -> Capability, showHiddenSection: Bool = false,
                            awaiting: Set<ItemKey> = [], timedOut: Set<ItemKey> = [], suppressedStatus: Set<ItemKey> = [],
                            pendingConfirmation: Set<ItemKey> = [], unverifiedAfterHandDrag: Set<ItemKey> = [],
                            coreRows: [ItemKey: Row]? = nil, coreNotes: [ItemKey: RowNote] = [:],
                            observationProblem: String? = nil, filter: String = "", units: HideUnitRule = .ownerKeys,
                            unitAppName: (String) -> String? = { _ in nil }, moveReasons: [ItemKey: String] = [:]) -> ArrangeContent {
        // A real bar always has items: an empty observation (or a failed one) means we know nothing about the bar.
        let hasObs = !observed.onBar.isEmpty && observationProblem == nil
        let onBar = Set(observed.onBar)
        let parked = Set(observed.parked)
        let pile = observed.systemOverflow.intersection(onBar).union(observed.foldedParked)   // gdu.121: folded parked keys are overflowed too

        // Arrange never re-derives what the engine would do (rows come from the core, D9). The only thing it
        // computes itself is whether a drawn key's immediate observed neighbours are the ones the record has (the check's evidence).
        let drawn = observed.onBar.filter { !pile.contains($0) && !$0.isOverflowChevron && $0 != observed.overflowChevron }
        let recordDrawn = layout.visible.filter { !$0.isOverflowChevron && drawn.contains($0) }
        let barRecordKeys = drawn.filter { layout.visible.contains($0) }
        /// Whether the key's immediate neighbours on the bar (leaving out the engine's held keys, which it does not move) are the record's.
        // gdu.144 D7: on EVERY bar a drawn row is a check only if ALL drawn trusted keys are in record order among themselves AND its own neighbours
        // are the record's; a hosted pile key (any chevron) is never a check.
        let trusted: (ItemKey) -> Bool = { !observed.uncorroborated.contains($0) && !observed.staleOnBar.contains($0) }
        // (held / given-up keys count: a key the engine gave up on is still a drawn key, and the others are not "in order" around it)
        let drawnAllInOrder = layout.visible.filter { !$0.isOverflowChevron && drawn.contains($0) && trusted($0) } == drawn.filter { layout.visible.contains($0) && trusted($0) }
        func neighboursAgree(_ k: ItemKey) -> Bool {
            if !drawnAllInOrder { return false }
            guard let i = recordDrawn.firstIndex(of: k), let j = barRecordKeys.firstIndex(of: k) else { return false }
            func at(_ a: [ItemKey], _ n: Int) -> ItemKey? { a.indices.contains(n) ? a[n] : nil }
            return at(recordDrawn, i - 1) == at(barRecordKeys, j - 1) && at(recordDrawn, i + 1) == at(barRecordKeys, j + 1)
        }

        let namer = RowNameRule.Namer(layout: layout, items: items)
        func title(_ k: ItemKey) -> String { namer.name(k) }
        func mates(_ k: ItemKey) -> [String] { layout.allKeys.filter { $0 != k && units.unit(of: $0) == units.unit(of: k) }.map(title) }

        func row(_ k: ItemKey, ghost: Bool, running: Bool) -> ArrangeRow {
            let cap = capabilities(k)
            let anchor = !cap.canMove
            let info = items[k]
            let pending = ghost || awaiting.contains(k)
            let stale = !ghost && observed.staleOnBar.contains(k) && !observed.carriedRecently.contains(k)   // gdu.120: recently verified rows look ordinary
            var b = hasObs
                ? badge(status: suppressedStatus.contains(k) ? nil : perItem[k], running: running, pendingPlacement: pending, isAnchor: anchor, timedOut: timedOut.contains(k),
                        pendingConfirmation: pendingConfirmation.contains(k))
                : .none
            if stale, hasObs, b == .none || b == .inPlace || b == .inPlacePending { b = .stale }
            var r = ArrangeRow(key: k, title: title(k), ownerName: info?.ownerName ?? "", ownerBundleID: info?.ownerBundleID ?? ownerBundleID(k),
                              ownerPID: info?.ownerPID, badge: b, draggable: cap.canMove, canHide: cap.canHide, isAnchor: anchor,
                              isGhost: ghost, isBoundary: observed.overflowChevron == k,
                              notFitting: observed.systemOverflow.contains(k), notRunning: !running, unit: units.unit(of: k),
                              unitMates: mates(k), unitApp: units.trackedKey(of: k).flatMap(unitAppName), capabilityNote: (cap.canMove && cap.canHide) ? nil : cap.reason)
            r.staleFrame = stale
            r.detail = namer.detail(k)
            if !anchor {
                r.movableTo = Set(LayoutSection.allCases.filter {
                    ArrangeDrop.canMove(layout: layout, key: k, to: $0, capabilities: capabilities, observationAvailable: hasObs, units: units, parked: parked)
                })
            }
            if b == .moving, !ghost { r.moveReason = moveReasons[k] }
            return r
        }

        func uncorroboratedNote(_ k: ItemKey) -> String { neighboursAgree(k) ? uncorroboratedText + " (it looks in place)" : uncorroboratedText }

        /// The bar's state for one Visible record key (see `ArrangeBarState`), with the badge and the optional "why it moves" text.
        func visibleRow(_ k: ItemKey, ghost: Bool) -> ArrangeRow {
            var r = row(k, ghost: ghost, running: true)
            r.isBoundary = false
            let suppressed = suppressedStatus.contains(k)
            let status = suppressed ? nil : perItem[k]
            let isAwaiting = awaiting.contains(k)
            let engineMoving: Bool = {
                switch status { case .pending?, .moving?: return true; default: return false }
            }()
            var state: ArrangeBarState
            var why: String?
            var note: String?
            var pinTimedOut = false
            var waitName: String?
            if timedOut.contains(k) {
                state = .cannotPlace(ArrangeTracker.timeoutText)
            } else if observed.foldedParked.contains(k), !(status.map { if case .failed = $0 { true } else { false } } ?? false) {
                // gdu.121: parked, allowed, running while « is fresh: folded for width. Never moving / waiting / not on the bar.
                state = .behindChevron
            } else if suppressed && isAwaiting {
                // Right after a drop, before a pass has judged it: the tracker's word, not the engine's last (older) plan.
                state = .moving
            } else if case .failed(let e)? = status {
                state = .cannotPlace(plainReason(describe(e)))
            } else if pile.contains(k), !engineMoving, !{ if case .cannotPlace? = status { return true } else { return false } }() {
                // gdu.144 rule 2: a folded row is « and never a warning merely for being in the pile or uncorroborated while in it (no unsupported /
                // waiting verdict reaches it). 9o9.24: « wins over ~ for a key the observation reports in the pile (both are true; « is the more
                // useful); the tooltip adds the other.
                state = .behindChevron
                note = ArrangeBarState.stayBehindText(title(k))
                if observed.staleOnBar.contains(k), !observed.carriedRecently.contains(k) {
                    note = ArrangeBarState.behindChevronText + "\n" + ArrangeBarState.staleText
                } else if observed.uncorroborated.contains(k) {
                    note = ArrangeBarState.behindChevronText + "\n" + uncorroboratedText
                }
            } else if case .unsupported(let reason)? = status, reason.hasPrefix(Self.positionTimeoutPrefix),
                      onBar.contains(k), !pile.contains(k), neighboursAgree(k) {
                // 9o9.29: the scan never corroborated this key's frame, but its observed neighbours are the record's: not a warning.
                state = .staleFrame
                note = pinnedDownTimeoutText
                pinTimedOut = true
            } else if case .unsupported(let reason)? = status {
                state = .cannotPlace(plainReason(reason))
            } else if case .cannotPlace(let reason, _)? = status {
                state = .cannotPlace(plainReason(reason))
            } else if ghost {
                state = engineMoving ? .moving : .notOnBar
            } else if unverifiedAfterHandDrag.contains(k) {
                state = .unreadAfterHandDrag
            } else if case .waitingForPosition? = status {
                // 9o9.24: "Position being re-read" is for STALE (carried) frames only; any other wait for a corroborated position reads the honest text.
                state = .staleFrame
                if !observed.staleOnBar.contains(k), observed.uncorroborated.contains(k) { note = uncorroboratedNote(k) }
            } else if r.staleFrame {
                state = .staleFrame
            } else if observed.uncorroborated.contains(k), !observed.staleOnBar.contains(k), onBar.contains(k), !pile.contains(k) {
                state = .staleFrame
                note = uncorroboratedNote(k)
            } else if engineMoving {
                state = .moving
            } else if onBar.contains(k), neighboursAgree(k) {
                state = .matches
            } else {
                state = .notConfirmed
                if !drawnAllInOrder, onBar.contains(k), !pile.contains(k) { note = ArrangeBarState.differsFromYourOrderText }
            }
            if let coreRows {   // D9: the Lean row first; Swift refines only within the same ok-class; a D5 timeout may only downgrade
                let core = coreRows[k]
                var positionTimedOut = false   // the position timeout (9o9.29) is a Swift timeout too: it may only downgrade
                if case .unsupported(let reason)? = status, reason.hasPrefix(Self.positionTimeoutPrefix) { positionTimedOut = true }
                let reconciled = CoreRowRule.reconcile(core: core, swift: state, timedOut: timedOut.contains(k) || positionTimedOut)
                if reconciled != state {
                    state = reconciled; note = nil; why = nil; waitName = nil; pinTimedOut = false
                    if core == .waiting { why = "Waiting for the bar to settle"; waitName = "the bar" }
                }
                if let n = coreNotes[k], core == .notWherePut || core == .cannotTell { note = CoreRowRule.text(n) }
            }
            r.barState = state
            r.stateNote = note
            r.pinDownTimedOut = pinTimedOut
            r.staleFrame = state == .staleFrame
            switch state {
            case .matches:
                r.badge = hasObs && !r.isAnchor && status != nil ? (pendingConfirmation.contains(k) ? .inPlacePending : .inPlace) : .none
            case .moving: r.badge = .moving; r.moveReason = why ?? moveReasons[k]; r.waitingOn = waitName
            case .cannotPlace(let reason): r.badge = .cannotPlace(reason)
            case .notOnBar: r.badge = .ghost
            case .notConfirmed: r.badge = .none
            case .staleFrame: r.badge = .stale
            case .behindChevron: r.badge = .behindChevron
            case .unreadAfterHandDrag: r.badge = .unreadAfterHandDrag
            }
            return r
        }

        // MARK: Visible = the record, in record order, with a state per row and the fold line after the last overflowed key
        var vRows: [ArrangeRow] = []
        var vNot: [ArrangeRow] = []
        if hasObs {
            for k in layout.visible where !k.isOverflowChevron {
                if onBar.contains(k) || observed.foldedParked.contains(k) { vRows.append(visibleRow(k, ghost: false)); continue }
                if case .module = k { continue }
                if items[k] == nil && !parked.contains(k) { vNot.append(row(k, ghost: false, running: false)); continue }
                vRows.append(visibleRow(k, ghost: true))
            }
            if !pile.isEmpty, !observed.stripExpanded,
               let last = vRows.lastIndex(where: { !$0.isGhost && pile.contains($0.key) }) {
                var line = row(observed.overflowChevron ?? .overflowChevron, ghost: false, running: true)
                line.isBoundary = true; line.badge = .none; line.barState = nil; line.draggable = false; line.movableTo = []
                vRows.insert(line, at: last + 1)
            }
        }

        // MARK: Hidden sections follow the layout
        func hiddenStrip(_ s: LayoutSection) -> ArrangeStrip {
            var rows: [ArrangeRow] = [], not: [ArrangeRow] = []
            for k in layout.keys(in: s) {
                let running = !hasObs || items[k] != nil || onBar.contains(k) || parked.contains(k)
                guard running else { not.append(row(k, ghost: false, running: false)); continue }
                let arriving = hasObs && onBar.contains(k) && !(s == .hidden && showHiddenSection)
                rows.append(row(k, ghost: arriving, running: true))
            }
            return ArrangeStrip(section: s, rows: rows, notRunning: not)
        }

        var out = ArrangeContent(visible: ArrangeStrip(section: .visible, rows: vRows, notRunning: vNot),
                                 hidden: hiddenStrip(.hidden), alwaysHidden: hiddenStrip(.alwaysHidden), observedAvailable: hasObs,
                                 visiblePlaceholder: hasObs ? nil : "No observation yet — " + (observationProblem ?? "scanning…"))
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !f.isEmpty {
            func keep(_ r: ArrangeRow) -> Bool {
                r.title.lowercased().contains(f) || r.detail.lowercased().contains(f) || r.ownerName.lowercased().contains(f) || (r.ownerBundleID?.lowercased().contains(f) ?? false)
            }
            for s in LayoutSection.allCases {
                var st = out.strip(s)
                st.rows = st.rows.filter(keep); st.notRunning = st.notRunning.filter(keep)
                switch s { case .visible: out.visible = st; case .hidden: out.hidden = st; case .alwaysHidden: out.alwaysHidden = st }
            }
        }
        // gdu.117: Move left / right enablement, judged on the strip's final (filtered) rows exactly like `ArrangeViewModel.step`.
        if hasObs, ArrangeMenuRules.showsStepItems() {
            let stepRows = out.visible.rows
            func name(_ k: ItemKey) -> String { items[k] != nil ? namer.name(k) : "\(k)" }
            func can(_ k: ItemKey, _ d: ArrangeDrop.Direction) -> Bool {
                if case .move = ArrangeDrop.step(layout: layout, rows: stepRows, key: k, d, capabilities: capabilities, observationAvailable: hasObs,
                                                 bar: observed.onBar, displayName: name, units: units) { return true }
                return false
            }
            func flag(_ r: ArrangeRow) -> ArrangeRow {
                guard !r.isAnchor, !r.isBoundary else { return r }
                var r = r; r.canStepLeft = can(r.key, .left); r.canStepRight = can(r.key, .right); return r
            }
            out.visible.rows = out.visible.rows.map(flag)
            out.visible.notRunning = out.visible.notRunning.map(flag)
        }
        return out
    }

    /// Display names for the pause text, nil once `until` has passed (gdu.60: not only after the next republish).
    public static func pollPausedNames(suppression: PollSuppression?, items: [ItemKey: ItemInfo], now: Date) -> [String]? {
        guard let s = suppression, s.until > now else { return nil }
        return s.keys.map { k in items[k].map { $0.ownerName } ?? "\(k)" }
    }

    static func pollPausedText(_ names: [String]) -> String {
        "Poll paused 5 min: \(names.isEmpty ? "an item" : names.joined(separator: ", ")) flapping"
    }

    /// gdu.73: status-line note during a PARTIAL reveal: how many items the planner skipped as "cannot be shown: ..." (gdu.15/gdu.74)
    /// while the reveal converges for the rest. nil when no reveal is active or nothing was skipped.
    public static func revealSkipNotice(perItem: [ItemKey: ItemStatus], showHiddenSection: Bool, showAlwaysHidden: Bool) -> String? {
        guard showHiddenSection || showAlwaysHidden else { return nil }
        let n = perItem.values.filter { if case .unsupported(let r) = $0 { return r.hasPrefix("cannot be shown") } else { return false } }.count
        guard n > 0 else { return nil }
        return n == 1 ? "1 item could not be shown" : "\(n) items could not be shown"
    }
    @MainActor public static func revealSkipNotice(state: EngineState) -> String? {
        revealSkipNotice(perItem: state.perItem, showHiddenSection: state.showHiddenSection, showAlwaysHidden: state.showAlwaysHidden)
    }

    /// gdu.144 rule 5: the status line while the bar-level hold is active (one text; it replaces the three "too narrow" variants).
    public static func barFullText(_ n: Int) -> String {
        if n <= 0 { return "The bar may be full: macOS did not accept the move. Press Re-apply layout to try again, or hide items to make room." }
        return "The bar is full: macOS folds \(n) item\(n == 1 ? "" : "s") behind «. Hide items to make room."
    }
    public static let checkingMenuBar = "Checking the menu bar…"
    public static let menuBarMatches = "Menu bar matches"
    public static let readingOrder = "Reading your menu bar order…"
    /// 9o9.29: drawn keys whose position the scan could not corroborate for a minute but whose neighbours agree with the record.
    public static func cannotPinDownText(_ n: Int) -> String { "\(n) item\(n == 1 ? "" : "s") can't be pinned down — right-click one to try again" }
}

// MARK: - Drops, steps and toolbar actions

/// Which keys of a submitted move the window tracks (spinner/timeout). Hidden-strip reorders are our own data (never tracked);
/// a reorder inside Visible is tracked (the bar must follow the record).
public func keysToTrack(moved: [ItemKey], old: Layout, new: Layout) -> [ItemKey] {
    moved.filter { k in
        let was = old.section(of: k), now = new.section(of: k)
        if was == now {
            if now != .visible { return false }
        }
        return true
    }
}

/// The layout the Arrange window submitted, until the engine has published it (so rapid consecutive drops build on each other).
/// Compared by REVISION, never by equality (gdu.48): the engine may append new items to the layout before it is published, so the
/// published layout can differ from the submitted one. While pending, further drops build on `effective(over:)`, which rebases the
/// pending copy onto the engine's layout (keys the engine added are kept), so they never drop the engine's additions.
public struct PendingLayout: Equatable, Sendable {
    public private(set) var layout: Layout?
    public private(set) var submittedRevision: Int?
    private var outstanding = 0
    public init() {}

    public var isActive: Bool { layout != nil }

    /// A layout was handed to `setLayout` (its revision is not known yet).
    public mutating func submit(_ l: Layout) { layout = l; outstanding += 1 }

    /// `setLayout` returned `revision` for one earlier `submit`.
    public mutating func submitted(revision: Int) {
        outstanding = max(0, outstanding - 1)
        submittedRevision = max(submittedRevision ?? revision, revision)
    }

    /// Clears the pending copy once every submission has returned its revision and the engine state has reached the latest one.
    @discardableResult
    public mutating func resolve(stateRevision: Int) -> Bool {
        guard layout != nil, outstanding == 0, let r = submittedRevision, stateRevision >= r else { return false }
        layout = nil; submittedRevision = nil
        return true
    }

    /// What the window should treat as the current layout: the engine's when nothing is pending, else the pending copy plus any
    /// key the engine added that the pending copy does not know.
    public func effective(over current: Layout) -> Layout {
        guard var l = layout else { return current }
        for k in current.allKeys where l.section(of: k) == nil {
            if let sec = current.section(of: k) { l.append(k, to: sec) }
        }
        return l
    }
}

public enum ArrangeCapabilities {
    /// Capability rules computed from the given `EngineState.items` (owning bundle ids) and the Control Center tracked set
    /// (`nil` = unreadable, everything hideable). Pure, so a headless caller resolves exactly like a UI drop.
    public static func rules(items: [ItemKey: ItemInfo], tracked: Set<String>?) -> CapabilityRules {
        let ids = items.compactMapValues(\.ownerBundleID)
        return EngineFactory.makeCapabilityRules(tracked: tracked, bundleID: { ids[$0] })
    }

    /// Same, with the resolver (helper keys listed in a parent's entry are hideable through it, gdu.68).
    public static func rules(items: [ItemKey: ItemInfo], resolver: TrackedEntryResolver?) -> CapabilityRules {
        let ids = items.compactMapValues(\.ownerBundleID)
        return EngineFactory.makeCapabilityRules(resolver: resolver, bundleID: { ids[$0] })
    }

    /// Capability only from the engine's own data: a key without `ItemInfo` (no observation yet, or the app is not running)
    /// is UNKNOWN, so everything is allowed and the engine decides (the capsule shows "⟳" until it reports). Modules are
    /// anchors by kind. Known items get the real `CapabilityRules` answer (with the owning bundle id from `ItemInfo`).
    public static func resolve(_ key: ItemKey, items: [ItemKey: ItemInfo], rules: any CapabilityProvider) -> Capability {
        if case .module = key { return rules.capability(for: key) }
        guard items[key] != nil else { return Capability(canMove: true, canHide: true) }
        return rules.capability(for: key)
    }
}

public enum ArrangeDrop {
    /// 9o9.3: refusal for a Visible drop while the upgrade adoption is pending and no clean observation has been read yet.
    public static let readingOrder = "Reading your menu bar order…"
    /// True when a drop changing Visible must be refused: the upgrade adoption is pending and no clean observation exists to adopt from.
    public static func adoptionRefusal(pending: Bool, cleanObservation: Bool, current: Layout, proposed: Layout) -> Bool {
        pending && !cleanObservation && proposed.visible != current.visible
    }
    public static let noObservation = "Can't put this item on the menu bar until Sommelier can read the bar."
    /// 9o9.5: a drop onto or into the trailing system block (Clock, Control Center, ...) is refused: macOS owns that end of the bar.
    public static let systemItemsAtRightEnd = "macOS keeps the system items at the right end"

    /// gdu.116: refusal texts for a payload whose SOURCE row cannot be picked up. The drag gesture is attached to every capsule
    /// (a gesture that appears or disappears mid-drag kills the NSDraggingSession), so "not draggable" is judged here, at drop time.
    public static let sourceStale = "Its position is not fresh right now (the app has not answered); try again in a moment."
    public static let sourceNotRunning = "It is not running; start the app to move it."
    public static let sourcePending = "A move of this item is still in progress; try again once it settles."
    public static let sourceFixed = "This item cannot be moved."

    /// Reason the dragged row may not be dropped, or nil when it may. `rows` are all rows of the window (every strip, including
    /// not-running ones); `fromGhost` says the drag started on the ghost capsule of a pending move. nil also when no row matches
    /// (the outcome rules decide), so the rule never refuses on missing data.
    public static func sourceRefusal(key: ItemKey, fromGhost: Bool, rows: [ArrangeRow]) -> String? {
        guard let row = rows.first(where: { $0.key == key && $0.isGhost == fromGhost }) else { return nil }
        if row.isGhost { return ArrangeMenuRules.ghostInteractive(row) ? nil : sourcePending }
        if row.draggable { return nil }
        if row.staleFrame { return sourceStale }
        if row.notRunning { return sourceNotRunning }
        return row.capabilityNote ?? sourceFixed
    }

    public enum Direction: Sendable { case left, right }

    public enum Outcome: Equatable, Sendable {
        /// The drop would not change the layout (e.g. dropped on its own position).
        case noop
        case rejected(String)
        /// `moved` lists every key that moves (the unit's siblings come along, `key` first). `willNotFit`: the target is left
        /// of the overflow boundary, so the item will land behind macOS's chevron.
        case move(layout: Layout, moved: [ItemKey], willNotFit: Bool)
    }

    /// Whether the context menu's "Move to `section`" is enabled for `key`: not already there (except a parked key listed Visible, where
    /// it is a show request, gdu.110) and `outcome` is a move. The single source for `ArrangeRow.movableTo` and `ArrangeViewModel.canMove`.
    public static func canMove(layout: Layout, key: ItemKey, to section: LayoutSection, capabilities: (ItemKey) -> Capability,
                               observationAvailable: Bool = true, units: HideUnitRule = .ownerKeys, parked: Set<ItemKey> = []) -> Bool {
        guard layout.section(of: key) != section || (section == .visible && parked.contains(key)) else { return false }
        if case .move = outcome(layout: layout, key: key, to: section, index: nil, capabilities: capabilities,
                                observationAvailable: observationAvailable, units: units, parked: parked) { return true }
        return false
    }

    /// Applies the move with capability checks. `index` is a position in `section` AFTER the unit is lifted out
    /// (`Layout.move` semantics); nil appends (Visible: before the trailing system block).
    public static func outcome(layout: Layout, key: ItemKey, to section: LayoutSection, index: Int?,
                               capabilities: (ItemKey) -> Capability, willNotFit: Bool = false, observationAvailable: Bool = true,
                               bar: [ItemKey] = [], displayName: (ItemKey) -> String = { "\($0)" },
                               units: HideUnitRule = .ownerKeys,
                               parked: Set<ItemKey> = []) -> Outcome {
        // `parked`: keys the observation reports off the bar (ObservedOrder.parked); a drop of such a key into Visible is a show request (gdu.110), not a reorder.
        let showRequest = section == .visible && layout.section(of: key) == .visible && parked.contains(key)
        // Only moves that stay inside our own data (Hidden <-> Always hidden) and plain Visible reorders (9o9.5: the record is edited; the
        // engine decides when it can act) may proceed without an observation.
        let visibleReorder = section == .visible && layout.section(of: key) == .visible && !showRequest
        // Visible -> Hidden / Always hidden is a membership request the engine applies once it can read the bar; only a drop that needs a
        // slot ON the bar (Hidden -> Visible, an unlisted key) is refused without an observation.
        if !observationAvailable, !visibleReorder, section == .visible || layout.section(of: key) == nil {
            return .rejected(noObservation)
        }
        let cap = capabilities(key)
        guard cap.canMove else { return .rejected(cap.reason ?? "This item cannot be moved.") }
        if section != .visible, !cap.canHide { return .rejected(cap.reason ?? "This item cannot be hidden.") }
        var l = layout
        let moved = l.move(key, to: section, index: index, units: units)
        if !showRequest, l.visible == layout.visible, l.hidden == layout.hidden, l.alwaysHidden == layout.alwaysHidden { return .noop }   // placement bookkeeping alone is no drop
        return .move(layout: l, moved: moved, willNotFit: willNotFit && section == .visible)
    }

    /// The `Layout.move` index for dropping into the gap `slot` (0...rows.count) of a strip: the position of the first row
    /// at or after the slot that is in the target section (rows of the moved unit and rows that are not in that section
    /// are skipped). nil = after everything (hidden: append; Visible: before the trailing system block). In Visible the
    /// index never exceeds the start of the trailing system block: dropping right of it clamps to before it.
    public static func index(layout: Layout, rows: [ArrangeRow], slot: Int, key: ItemKey, section: LayoutSection, units: HideUnitRule = .ownerKeys) -> Int? {
        let unit = units.unit(of: key)
        let lifted = layout.keys(in: section).filter { units.unit(of: $0) != unit }
        if section == .visible {
            // gdu.101: resolve by NEIGHBOUR KEYS. The nearest fresh, non-boundary row left of the slot that the layout lists
            // (the unit lifted out): insert right after it; else the nearest such row right of the slot: insert right before it.
            // A ghost stands for its key at the layout slot (a legitimate neighbour); the REAL capsule of a ghosted key is skipped.
            func usable(_ r: ArrangeRow) -> Int? {
                if r.isBoundary || units.unit(of: r.key) == unit { return nil }
                return lifted.firstIndex(of: r.key)
            }
            let at = min(max(0, slot), rows.count)
            var right: Int?
            for j in at..<rows.count where right == nil { right = usable(rows[j]) }
            for j in stride(from: at - 1, through: 0, by: -1) {
                if let p = usable(rows[j]) {
                    // gdu.119: right after the left neighbour, unless only anchors (modules, e.g. the chevron module) sit between it and
                    // the real right neighbour: then land directly before that neighbour so the layout records both drop neighbours.
                    var i = p + 1
                    if let r = right, r > i, lifted[i..<r].allSatisfy({ if case .module = $0 { return true } else { return false } }) { i = r }
                    return clamp(i, in: lifted, section: section)
                }
            }
            if let r = right { return clamp(r, in: lifted, section: section) }
            return nil
        }
        var idx: Int?
        var s = max(0, slot)
        while s < rows.count {
            let r = rows[s]
            s += 1
            if !r.isGhost, rows.contains(where: { $0.key == r.key && $0.isGhost }) { continue }
            if let p = lifted.firstIndex(of: r.key) { idx = p; break }
        }
        guard let i = idx else { return nil }
        return clamp(i, in: lifted, section: section)
    }

    /// Visible: an index is clamped into the movable span, after the leading run of anchors and before the trailing system
    /// block (third-party items cannot sit right of it). `lifted` is the section without the moving unit.
    static func clamp(_ i: Int, in lifted: [ItemKey], section: LayoutSection) -> Int {
        guard section == .visible else { return i }
        var lead = 0
        while lead < lifted.count, case .module = lifted[lead] { lead += 1 }
        var end = lifted.count
        while end > 0, case .module = lifted[end - 1] { end -= 1 }
        return max(min(i, end), min(lead, end))
    }

    /// Layout index for "the n-th MOVABLE position" (0-based; modules do not count): just before movable item n of the
    /// section (unit lifted out), nil when n is past the last one. Index 0 is the first movable slot, after any leading
    /// anchors. Used by the `SOMMELIER_ARRANGE_MOVE` hook so it goes through the same clamp as a UI drop.
    public static func index(layout: Layout, movableIndex n: Int, key: ItemKey, section: LayoutSection, units: HideUnitRule = .ownerKeys) -> Int? {
        let unit = units.unit(of: key)
        let lifted = layout.keys(in: section).filter { units.unit(of: $0) != unit }
        let movable = lifted.indices.filter { if case .module = lifted[$0] { return false } else { return true } }
        guard n >= 0, n < movable.count else { return nil }
        return clamp(movable[n], in: lifted, section: section)
    }

    /// The same drop as the UI, addressed by movable index (see above).
    public static func drop(layout: Layout, key: ItemKey, section: LayoutSection, movableIndex: Int?,
                            capabilities: (ItemKey) -> Capability, observationAvailable: Bool = true,
                            bar: [ItemKey] = [], displayName: (ItemKey) -> String = { "\($0)" },
                            units: HideUnitRule = .ownerKeys, parked: Set<ItemKey> = []) -> Outcome {
        let idx = movableIndex.flatMap { index(layout: layout, movableIndex: $0, key: key, section: section, units: units) }
        return outcome(layout: layout, key: key, to: section, index: idx, capabilities: capabilities, observationAvailable: observationAvailable,
                       bar: bar, displayName: displayName, units: units, parked: parked)
    }

    /// True when `slot` lies strictly inside or after the trailing run of system modules (anchors) of the Visible strip. The gap right
    /// before the first trailing module is still "before the system block" and allowed.
    static func intoSystemBlock(rows: [ArrangeRow], slot: Int) -> Bool {
        var start = rows.count
        while start > 0, rows[start - 1].isAnchor, !rows[start - 1].isBoundary, case .module = rows[start - 1].key { start -= 1 }
        return start < rows.count && slot > start
    }

    /// Full drop: slot in the displayed strip -> outcome.
    public static func drop(layout: Layout, rows: [ArrangeRow], slot: Int, key: ItemKey, section: LayoutSection,
                            capabilities: (ItemKey) -> Capability, observationAvailable: Bool = true,
                            bar: [ItemKey] = [], displayName: (ItemKey) -> String = { "\($0)" },
                            units: HideUnitRule = .ownerKeys, parked: Set<ItemKey> = []) -> Outcome {
        // 9o9.5: a Visible drop edits the record wherever it lands, except onto / into the trailing system block.
        if section == .visible, layout.section(of: key) == .visible, intoSystemBlock(rows: rows, slot: slot) { return .rejected(systemItemsAtRightEnd) }
        let idx = index(layout: layout, rows: rows, slot: slot, key: key, section: section, units: units)
        let boundary = rows.firstIndex { $0.isBoundary }
        let notFit = boundary.map { slot <= $0 } ?? false
        return outcome(layout: layout, key: key, to: section, index: idx, capabilities: capabilities, willNotFit: notFit,
                       observationAvailable: observationAvailable, bar: bar, displayName: displayName, units: units, parked: parked)
    }

    /// "Move left/right" inside Visible: past the next movable capsule (anchors, the boundary and ghosts are skipped; the
    /// trailing system block is therefore never crossed).
    public static func step(layout: Layout, rows: [ArrangeRow], key: ItemKey, _ dir: Direction,
                            capabilities: (ItemKey) -> Capability, observationAvailable: Bool = true,
                            bar: [ItemKey] = [], displayName: (ItemKey) -> String = { "\($0)" },
                            units: HideUnitRule = .ownerKeys) -> Outcome {
        guard let r = rows.firstIndex(where: { $0.key == key && !$0.isBoundary }), layout.visible.contains(key) else { return .noop }
        let unit = units.unit(of: key)
        let lifted = layout.visible.filter { units.unit(of: $0) != unit }
        let seq: [Int] = dir == .left ? Array(stride(from: r - 1, through: 0, by: -1)) : Array(((r + 1)..<max(r + 1, rows.count)))
        for j in seq {
            let c = rows[j]
            guard !c.isAnchor, !c.isBoundary, units.unit(of: c.key) != unit, let p = lifted.firstIndex(of: c.key) else { continue }
            let notFit = c.notFitting && dir == .left
            return outcome(layout: layout, key: key, to: .visible, index: dir == .left ? p : p + 1, capabilities: capabilities, willNotFit: notFit,
                           bar: bar, displayName: displayName, units: units)
        }
        return .noop
    }

    /// "Hide what does not fit": the overflowed visible keys (with their hide-unit siblings) move to the end of Hidden.
    /// `blocked` lists overflowed keys that cannot be hidden (Apple apps, untracked apps); they stay.
    public static func hideNotFitting(layout: Layout, observed: ObservedOrder,
                                      capabilities: (ItemKey) -> Capability,
                                      units: HideUnitRule = .ownerKeys) -> (layout: Layout, moved: [ItemKey], blocked: [ItemKey]) {
        // gdu.144 rule 6: every folded key, the pile AND the keys macOS folds for width (folded-parked), is hidden; the caller passes `moved` as the edit's keys.
        let keys = layout.visible.filter { (observed.systemOverflow.contains($0) || observed.foldedParked.contains($0)) && $0 != observed.overflowChevron }
        let ok = keys.filter { capabilities($0).canHide && capabilities($0).canMove }
        let blocked = keys.filter { k in !ok.contains(k) }
        var l = layout
        let moved = l.hideNotFitting(ok, units: units)
        return (l, moved, blocked)
    }

    /// "Adopt current order": Visible = the observed bar verbatim (modules included, as `LayoutBuilder` does), Hidden = the
    /// parked items, except that keys the current layout keeps in Always hidden stay there. Layout keys that are not
    /// observed (apps not running) keep their section, appended at the end. The new item policy is preserved.
    public static func adopt(observed: ObservedOrder, current: Layout, units: HideUnitRule = .ownerKeys) -> Layout {
        var l = Layout(newItemPolicy: current.newItemPolicy)
        var seen = Set<ItemKey>()
        for k in observed.onBar where !k.isOverflowChevron && k != observed.overflowChevron && seen.insert(k).inserted { l.visible.append(k) }
        let always = Set(current.alwaysHidden)
        for k in observed.parked where !k.isOverflowChevron && seen.insert(k).inserted {
            if always.contains(k) { l.alwaysHidden.append(k) } else { l.hidden.append(k) }
        }
        for s in LayoutSection.allCases {
            for k in current.keys(in: s) where !k.isOverflowChevron && seen.insert(k).inserted {
                switch s {
                case .visible:
                    var at = l.visible.count   // before the trailing system block: right of it is unreachable
                    while at > 0, case .module = l.visible[at - 1] { at -= 1 }
                    l.visible.insert(k, at: at)
                case .hidden: l.hidden.append(k)
                case .alwaysHidden: l.alwaysHidden.append(k)
                }
            }
        }
        return l.normalizedHideUnits(units: units).layout
    }
}

// MARK: - Drop tracking (the waiting state machine)

/// Tracks submitted moves until the real bar agrees. Pure: driven by the engine's published values and a clock.
/// Rules: (1) a drop is judged only by a pass that STARTED after it (`passSequence > dropSequence`, where `dropSequence` is
/// `passesStarted` at drop time); status from before that pass (an old failure, an old "in place") is suppressed and the
/// capsule shows "⟳". (2) "✓" needs that pass AND an in-place status AND `placementMatches`; there is no path to "✓" from the
/// engine status alone. (3) A failed/unsupported status from a judging pass ends the wait (the badge then shows it).
/// (4) After `timeout` seconds without a match the capsule shows the timeout "⚠"; a later match clears it.
/// (5) Retry resets the sequence so the retry is judged by a fresh pass.
/// gdu.119: what a Visible drop asked for, as neighbour KEYS: the nearest real row left and right of the slot (nil = start / end).
public struct DropIntent: Equatable, Sendable {
    public var key: ItemKey
    public var left: ItemKey?
    public var right: ItemKey?
    public init(key: ItemKey, left: ItemKey?, right: ItemKey?) { self.key = key; self.left = left; self.right = right }

    /// Real rows (ghosts, the boundary and the dragged key skipped) left and right of `slot`.
    public static func from(rows: [ArrangeRow], slot: Int, key: ItemKey) -> DropIntent {
        let at = min(max(0, slot), rows.count)
        return DropIntent(key: key, left: rows[..<at].last { !$0.isGhost && !$0.isBoundary && $0.key != key }?.key,
                          right: rows[at...].first { !$0.isGhost && !$0.isBoundary && $0.key != key }?.key)
    }

    /// True when the observed bar has `key` directly between `left` and `right` (the overflow chevron is not a neighbour; a nil
    /// side is unconstrained). False when the key is not on the bar.
    public func holds(in o: ObservedOrder) -> Bool {
        let bar = o.onBar.filter { $0 != o.overflowChevron }
        guard let i = bar.firstIndex(of: key), !o.staleOnBar.contains(key) else { return false }
        if let l = left, !(i > 0 && bar[i - 1] == l) { return false }
        if let r = right, !(i + 1 < bar.count && bar[i + 1] == r) { return false }
        return left != nil || right != nil
    }
}

public struct ArrangeTracker: Equatable, Sendable {
    public static let timeout: TimeInterval = 90
    public static let timeoutText = "Arrange window timeout: the menu bar still does not match the layout after 90 s (the engine may still be working, or other items' saved order disagrees with the bar)"

    /// `awaitingStamp`: the drop's layout has been submitted but the engine has not yet reported the revision it produced
    /// (`stamp`); such an entry is never judged. `ticket` identifies the submission.
    public struct Entry: Equatable, Sendable {
        public var dropSequence: Int
        public var since: Date
        public var awaitingStamp: Bool = false
        public var ticket: Int = 0
        /// gdu.102: the `drop#<n>` of the gesture that created this entry (nil for actions that are not drops).
        public var dropID: Int?
        /// gdu.119: the neighbours the user dropped between. When the bar already shows the key between them the drop is applied.
        public var intent: DropIntent?
    }
    private var nextTicket = 0
    public private(set) var entries: [ItemKey: Entry] = [:]
    public private(set) var timedOut: Set<ItemKey> = []
    private var lastUpdate: Date?
    public init() {}

    public var awaiting: Set<ItemKey> { Set(entries.keys) }
    public var isEmpty: Bool { entries.isEmpty }

    /// gdu.117: everything the Arrange window renders from the tracker (which keys wait, their judging gate, the timed-out set). The
    /// bookkeeping `update` rewrites every tick (`lastUpdate`, `since`) is not part of it, so a quiet tick leaves it equal.
    public struct RenderState: Equatable, Sendable {
        var gates: [ItemKey: [Int]]
        var timedOut: Set<ItemKey>
    }
    public var renderState: RenderState {
        RenderState(gates: entries.mapValues { [$0.dropSequence, $0.awaitingStamp ? 1 : 0] }, timedOut: timedOut)
    }

    /// Keys whose current engine status predates their judging pass.
    /// While the observation is unsettled (gdu.46) no engine status can be trusted (an unsettled pass refreshes none), so every
    /// tracked key is suppressed.
    ///
    /// 9o9.5: `planPass` is `lastPlan.passStarted` (the pass that PUBLISHED the latest plan). When given, the drop is handed over only to
    /// a plan published by a pass that started after it: a busy-skipped pass bumps `passSequence` but publishes no plan, so the row keeps
    /// its ⟳ instead of going blank while the status line says "Moving…".
    public func suppressed(passSequence: Int, observationSettled: Bool = true, planPass: Int? = nil) -> Set<ItemKey> {
        if !observationSettled { return Set(entries.keys) }
        return Set(entries.filter { _, e in
            e.awaitingStamp || passSequence <= e.dropSequence || (planPass.map { $0 <= e.dropSequence } ?? false)
        }.keys)
    }

    /// Records a submitted move (unit siblings together). Re-recording a key restarts its wait.
    ///
    /// `awaitingStamp: true` (a drop that goes through `LayoutEngine.setLayout`): the entry is not judged until `stamp(ticket:...)`
    /// supplies the engine's `passesStartedAtRevision` for the revision this drop produced (gdu.48). The returned ticket names
    /// this submission. Without it, `passesStarted` is the stamp (an action that publishes no layout).
    @discardableResult
    public mutating func record(_ keys: [ItemKey], passesStarted: Int, now: Date, awaitingStamp: Bool = false, dropID: Int? = nil, intent: DropIntent? = nil) -> Int {
        nextTicket += 1
        for k in keys {
            entries[k] = Entry(dropSequence: passesStarted, since: now, awaitingStamp: awaitingStamp, ticket: nextTicket, dropID: dropID,
                               intent: k == intent?.key ? intent : nil)
            timedOut.remove(k)
        }
        return nextTicket
    }

    public mutating func retry(passesStarted: Int, now: Date) {
        for k in entries.keys { entries[k] = Entry(dropSequence: passesStarted, since: now, ticket: entries[k]?.ticket ?? 0, dropID: entries[k]?.dropID, intent: entries[k]?.intent) }
        timedOut = []
    }

    /// The engine published the layout of submission `ticket` as a revision that had `passesStartedAtRevision` passes started:
    /// only passes started after that count (`passSequence > passesStartedAtRevision`). Entries re-recorded or retried since
    /// carry another ticket / are no longer awaiting and are left alone.
    public mutating func stamp(ticket: Int, passesStartedAtRevision: Int) {
        for (k, e) in entries where e.ticket == ticket && e.awaitingStamp {
            entries[k]?.dropSequence = passesStartedAtRevision
            entries[k]?.awaitingStamp = false
        }
    }

    public mutating func removeAll() { entries = [:]; timedOut = [] }

    /// Advances the machine; returns log lines for resolved entries.
    @discardableResult
    public mutating func update(observed: ObservedOrder, layout: Layout, perItem: [ItemKey: ItemStatus], passSequence: Int,
                                showHiddenSection: Bool, now: Date, observationSettled: Bool = true, planPass: Int? = nil) -> [String] {
        defer { lastUpdate = now }
        // An unsettled observation judges nothing (no check mark, no failure) and does not run the timeout clock: the wait
        // is extended by the time spent unsettled. `passSequence` still advances (every started pass finishes), so judging
        // resumes at the next settled state with `passSequence > dropSequence`.
        guard observationSettled else {
            if let last = lastUpdate { let dt = now.timeIntervalSince(last); for k in entries.keys { entries[k]?.since += dt } }
            return []
        }
        var log: [String] = []
        // gdu.102: with a drop id the line reads "drop#n done: <text>; final: between A and B" (observed bar order).
        func line(_ e: Entry, _ k: ItemKey, _ text: String) -> String {
            guard let id = e.dropID else { return text }
            return DropTrace.doneLine(id: id, outcome: "\(text); final: \(DropTrace.between(k, in: observed.onBar))")
        }
        for (k, e) in entries {
            guard layout.section(of: k) != nil else { entries[k] = nil; timedOut.remove(k); continue }
            let dt = now.timeIntervalSince(e.since)
            // gdu.119: the bar already shows the key between the neighbours the user dropped it between: nothing to wait for
            // (mode-independent; the whole-layout comparison below can disagree over items the drop did not touch).
            if let i = e.intent, i.holds(in: observed) {
                var blocked = false
                switch perItem[k] { case .failed?, .unsupported?: blocked = true; default: break }
                if !blocked {
                    entries[k] = nil; timedOut.remove(k)
                    log.append(line(e, k, "applied (already between the dropped neighbours, \(String(format: "%.1f", dt))s after the drop)"))
                    continue
                }
            }
            if !e.awaitingStamp, passSequence > e.dropSequence, planPass.map({ $0 > e.dropSequence }) ?? true {
                switch perItem[k] {
                case .failed(let err)?:
                    entries[k] = nil; timedOut.remove(k)
                    log.append(line(e, k, "\(k) FAILED \(String(format: "%.1f", dt))s after the drop: \(ArrangeSections.describe(err))"))
                    continue
                case .unsupported(let r)?:
                    entries[k] = nil; timedOut.remove(k)
                    log.append(line(e, k, "\(k) unsupported \(String(format: "%.1f", dt))s after the drop: \(r)"))
                    continue
                case .cannotPlace(let r, _)?:
                    entries[k] = nil; timedOut.remove(k)
                    log.append(line(e, k, "\(k) cannot be placed \(String(format: "%.1f", dt))s after the drop: \(r)"))
                    continue
                case let st? where st == .inPlace || st == .notFitting:
                    if ArrangeSections.placementMatches(k, layout: layout, observed: observed, showHiddenSection: showHiddenSection) {
                        entries[k] = nil; timedOut.remove(k)
                        log.append(line(e, k, "\(k) verified in place \(String(format: "%.1f", dt))s after the drop (observed order matches)"))
                        continue
                    }
                default: break
                }
            }
            if dt > Self.timeout, timedOut.insert(k).inserted { log.append(line(e, k, "\(k) NOT applied after \(Int(Self.timeout))s")) }
        }
        return log
    }
}
