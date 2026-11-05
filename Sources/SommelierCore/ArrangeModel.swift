import Foundation

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

    public var glyph: String {
        switch self {
        case .none: return ""
        case .inPlace: return "✓"
        case .inPlacePending: return "✓"
        case .moving: return "⟳"
        case .failed: return "⚠"
        case .cannotChange: return "⊘"
        case .notFitting: return "⇠"
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
    /// Capability reason when the item cannot be moved or hidden (rendered as a small ⊘).
    public var capabilityNote: String?
    public var id: String { isGhost ? key.description + "#ghost" : key.description }

    public var unitTooltip: String? { unitMates.isEmpty ? nil : "Hides together with " + unitMates.joined(separator: ", ") }
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
    /// Shown for self-positioning items (iStat Menus): Sommelier never drags them and does not manage their order.
    public static let positionsItselfNote = "Positions itself: Sommelier does not manage this item's order."
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
    public static func placementMatches(_ key: ItemKey, layout: Layout, observed: ObservedOrder, showHiddenSection: Bool = false) -> Bool {
        guard let sec = layout.section(of: key) else { return true }
        switch sec {
        case .visible:
            guard observed.onBar.contains(key) else { return false }
            return drawnOrder(layout.visible, observed) == drawnOrder(observed.onBar, observed, within: layout.visible)
        case .hidden:
            return observed.parked.contains(key) || (showHiddenSection && observed.onBar.contains(key))
        case .alwaysHidden:
            return observed.parked.contains(key)
        }
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

    /// Builds the three strips. Visible mirrors the OBSERVED bar (no optimistic reordering) with ghosts at the target slots
    /// of pending moves; Hidden/Always hidden follow the layout order (our own data, so they reorder optimistically).
    public static func make(observed: ObservedOrder, layout: Layout, items: [ItemKey: ItemInfo], perItem: [ItemKey: ItemStatus],
                            capabilities: (ItemKey) -> Capability, showHiddenSection: Bool = false,
                            awaiting: Set<ItemKey> = [], timedOut: Set<ItemKey> = [], suppressedStatus: Set<ItemKey> = [],
                            pendingConfirmation: Set<ItemKey> = [],
                            observationProblem: String? = nil, filter: String = "") -> ArrangeContent {
        // A real bar always has items: an empty observation (or a failed one) means we know nothing about the bar.
        let hasObs = !observed.onBar.isEmpty && observationProblem == nil
        let onBar = Set(observed.onBar)
        let parked = Set(observed.parked)

        func title(_ k: ItemKey) -> String { items[k].map(OverflowEntries.displayName) ?? fallbackTitle(k) }
        func mates(_ k: ItemKey) -> [String] { layout.allKeys.filter { $0 != k && $0.hideUnit == k.hideUnit }.map(title) }

        func row(_ k: ItemKey, ghost: Bool, running: Bool) -> ArrangeRow {
            let cap = capabilities(k)
            let anchor = !cap.canMove
            let info = items[k]
            let pending = ghost || awaiting.contains(k)
            let b = hasObs
                ? badge(status: suppressedStatus.contains(k) ? nil : perItem[k], running: running, pendingPlacement: pending, isAnchor: anchor, timedOut: timedOut.contains(k),
                        pendingConfirmation: pendingConfirmation.contains(k))
                : .none
            return ArrangeRow(key: k, title: title(k), ownerName: info?.ownerName ?? "", ownerBundleID: info?.ownerBundleID ?? ownerBundleID(k),
                              ownerPID: info?.ownerPID, badge: b, draggable: cap.canMove, canHide: cap.canHide, isAnchor: anchor,
                              isGhost: ghost, isBoundary: observed.overflowChevron == k,
                              notFitting: observed.systemOverflow.contains(k), notRunning: !running, unit: k.hideUnit,
                              unitMates: mates(k), capabilityNote: (cap.canMove && cap.canHide) ? (SelfPositioning.isSelfPositioning(k) ? ArrangeSections.positionsItselfNote : nil) : cap.reason)
        }

        // MARK: Visible = the observed bar + ghosts at layout slots + not-running group
        var vRows: [ArrangeRow] = []
        var vNot: [ArrangeRow] = []
        if hasObs {
            vRows = observed.onBar.map { row($0, ghost: false, running: true) }
            let lv = layout.visible
            for (i, k) in lv.enumerated() {
                var ghost = false
                if !onBar.contains(k) {
                    if case .module = k { continue }
                    if items[k] == nil && !parked.contains(k) { vNot.append(row(k, ghost: false, running: false)); continue }
                    ghost = true
                } else if awaiting.contains(k) && !placementMatches(k, layout: layout, observed: observed, showHiddenSection: showHiddenSection) {
                    ghost = true
                }
                guard ghost else { continue }
                let g = row(k, ghost: true, running: true)
                func at(_ key: ItemKey) -> Int? {
                    vRows.lastIndex { $0.key == key && $0.isGhost } ?? vRows.lastIndex { $0.key == key }
                }
                var insertAt: Int?
                for j in stride(from: i - 1, through: 0, by: -1) where insertAt == nil {
                    if let p = at(lv[j]) { insertAt = p + 1 }
                }
                if insertAt == nil {
                    for j in (i + 1)..<max(i + 1, lv.count) where insertAt == nil {
                        if let p = vRows.firstIndex(where: { $0.key == lv[j] }) { insertAt = p }
                    }
                }
                if insertAt == nil {
                    var s = vRows.count
                    while s > 0, case .module = vRows[s - 1].key { s -= 1 }
                    insertAt = s
                }
                vRows.insert(g, at: insertAt!)
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
                r.title.lowercased().contains(f) || r.ownerName.lowercased().contains(f) || (r.ownerBundleID?.lowercased().contains(f) ?? false)
            }
            for s in LayoutSection.allCases {
                var st = out.strip(s)
                st.rows = st.rows.filter(keep); st.notRunning = st.notRunning.filter(keep)
                switch s { case .visible: out.visible = st; case .hidden: out.hidden = st; case .alwaysHidden: out.alwaysHidden = st }
            }
        }
        return out
    }

    static func pollPausedText(_ names: [String]) -> String {
        "Poll paused 5 min: \(names.isEmpty ? "an item" : names.joined(separator: ", ")) flapping"
    }

    /// Bottom line: errors and counts first, "Converged" only when nothing is pending or failed.
    public static func statusLine(perItem: [ItemKey: ItemStatus], lastError: EngineError?, isConverged: Bool, inFlight: Bool,
                                  pendingAwaiting: Int = 0, observationSettled: Bool = true,
                                  notice: String? = nil, pollPausedNames: [String]? = nil) -> String {
        let pending = perItem.values.filter { if case .pending = $0 { return true }; if case .moving = $0 { return true }; return false }.count
        let failed = perItem.values.filter { if case .failed = $0 { return true }; return false }.count
        let base = StatusLine.text(lastError: lastError, isConverged: isConverged, inFlight: inFlight, trusted: true, conflicting: nil,
                                  observationSettled: observationSettled)
        var parts: [String] = []
        if lastError != nil { parts.append(base) }
        let n = max(pending, pendingAwaiting)
        if n > 0 { parts.append("\(n) pending") }
        if failed > 0 { parts.append("\(failed) failed") }
        if parts.isEmpty {
            var line = notice.map { "\($0) · \(base)" } ?? base
            if let n = pollPausedNames { line += " · " + pollPausedText(n) }
            return line
        }
        if let notice { parts.insert(notice, at: 0) }
        if let n = pollPausedNames { parts.append(pollPausedText(n)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Drops, steps and toolbar actions

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
    public static let noObservation = "No observation of the menu bar yet: moving items needs one."

    public enum Direction: Sendable { case left, right }

    public enum Outcome: Equatable, Sendable {
        /// The drop would not change the layout (e.g. dropped on its own position).
        case noop
        case rejected(String)
        /// `moved` lists every key that moves (the unit's siblings come along, `key` first). `willNotFit`: the target is left
        /// of the overflow boundary, so the item will land behind macOS's chevron.
        case move(layout: Layout, moved: [ItemKey], willNotFit: Bool)
    }

    /// Applies the move with capability checks. `index` is a position in `section` AFTER the unit is lifted out
    /// (`Layout.move` semantics); nil appends (Visible: before the trailing system block).
    public static func outcome(layout: Layout, key: ItemKey, to section: LayoutSection, index: Int?,
                               capabilities: (ItemKey) -> Capability, willNotFit: Bool = false, observationAvailable: Bool = true) -> Outcome {
        // Only moves that stay inside our own data (Hidden <-> Always hidden) may proceed without an observation.
        if !observationAvailable, section == .visible || layout.section(of: key) == .visible || layout.section(of: key) == nil {
            return .rejected(noObservation)
        }
        let cap = capabilities(key)
        guard cap.canMove else { return .rejected(cap.reason ?? "This item cannot be moved.") }
        if section != .visible, !cap.canHide { return .rejected(cap.reason ?? "This item cannot be hidden.") }
        var l = layout
        let moved = l.move(key, to: section, index: index)
        if l == layout { return .noop }
        return .move(layout: l, moved: moved, willNotFit: willNotFit && section == .visible)
    }

    /// The `Layout.move` index for dropping into the gap `slot` (0...rows.count) of a strip: the position of the first row
    /// at or after the slot that is in the target section (rows of the moved unit and rows that are not in that section
    /// are skipped). nil = after everything (hidden: append; Visible: before the trailing system block). In Visible the
    /// index never exceeds the start of the trailing system block: dropping right of it clamps to before it.
    public static func index(layout: Layout, rows: [ArrangeRow], slot: Int, key: ItemKey, section: LayoutSection) -> Int? {
        let unit = key.hideUnit
        let lifted = layout.keys(in: section).filter { $0.hideUnit != unit }
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
    public static func index(layout: Layout, movableIndex n: Int, key: ItemKey, section: LayoutSection) -> Int? {
        let unit = key.hideUnit
        let lifted = layout.keys(in: section).filter { $0.hideUnit != unit }
        let movable = lifted.indices.filter { if case .module = lifted[$0] { return false } else { return true } }
        guard n >= 0, n < movable.count else { return nil }
        return clamp(movable[n], in: lifted, section: section)
    }

    /// The same drop as the UI, addressed by movable index (see above).
    public static func drop(layout: Layout, key: ItemKey, section: LayoutSection, movableIndex: Int?,
                            capabilities: (ItemKey) -> Capability, observationAvailable: Bool = true) -> Outcome {
        let idx = movableIndex.flatMap { index(layout: layout, movableIndex: $0, key: key, section: section) }
        return outcome(layout: layout, key: key, to: section, index: idx, capabilities: capabilities, observationAvailable: observationAvailable)
    }

    /// Full drop: slot in the displayed strip -> outcome.
    public static func drop(layout: Layout, rows: [ArrangeRow], slot: Int, key: ItemKey, section: LayoutSection,
                            capabilities: (ItemKey) -> Capability, observationAvailable: Bool = true) -> Outcome {
        let idx = index(layout: layout, rows: rows, slot: slot, key: key, section: section)
        let boundary = rows.firstIndex { $0.isBoundary }
        let notFit = boundary.map { slot <= $0 } ?? false
        return outcome(layout: layout, key: key, to: section, index: idx, capabilities: capabilities, willNotFit: notFit,
                       observationAvailable: observationAvailable)
    }

    /// "Move left/right" inside Visible: past the next movable capsule (anchors, the boundary and ghosts are skipped; the
    /// trailing system block is therefore never crossed).
    public static func step(layout: Layout, rows: [ArrangeRow], key: ItemKey, _ dir: Direction,
                            capabilities: (ItemKey) -> Capability, observationAvailable: Bool = true) -> Outcome {
        guard observationAvailable else { return .rejected(noObservation) }
        guard let r = rows.firstIndex(where: { $0.key == key && !$0.isGhost }), layout.visible.contains(key) else { return .noop }
        let unit = key.hideUnit
        let lifted = layout.visible.filter { $0.hideUnit != unit }
        let seq: [Int] = dir == .left ? Array(stride(from: r - 1, through: 0, by: -1)) : Array(((r + 1)..<max(r + 1, rows.count)))
        for j in seq {
            let c = rows[j]
            guard !c.isAnchor, !c.isBoundary, !c.isGhost, c.key.hideUnit != unit, let p = lifted.firstIndex(of: c.key) else { continue }
            let notFit = c.notFitting && dir == .left
            return outcome(layout: layout, key: key, to: .visible, index: dir == .left ? p : p + 1, capabilities: capabilities, willNotFit: notFit)
        }
        return .noop
    }

    /// "Hide what does not fit": the overflowed visible keys (with their hide-unit siblings) move to the end of Hidden.
    /// `blocked` lists overflowed keys that cannot be hidden (Apple apps, untracked apps); they stay.
    public static func hideNotFitting(layout: Layout, observed: ObservedOrder,
                                      capabilities: (ItemKey) -> Capability) -> (layout: Layout, moved: [ItemKey], blocked: [ItemKey]) {
        let keys = layout.visible.filter { observed.systemOverflow.contains($0) && $0 != observed.overflowChevron }
        let ok = keys.filter { capabilities($0).canHide && capabilities($0).canMove }
        let blocked = keys.filter { k in !ok.contains(k) }
        var l = layout
        let moved = l.hideNotFitting(ok)
        return (l, moved, blocked)
    }

    /// "Adopt current order": Visible = the observed bar verbatim (modules included, as `LayoutBuilder` does), Hidden = the
    /// parked items, except that keys the current layout keeps in Always hidden stay there. Layout keys that are not
    /// observed (apps not running) keep their section, appended at the end. The new item policy is preserved.
    public static func adopt(observed: ObservedOrder, current: Layout) -> Layout {
        var l = Layout(newItemPolicy: current.newItemPolicy)
        var seen = Set<ItemKey>()
        for k in observed.onBar where seen.insert(k).inserted { l.visible.append(k) }
        let always = Set(current.alwaysHidden)
        for k in observed.parked where seen.insert(k).inserted {
            if always.contains(k) { l.alwaysHidden.append(k) } else { l.hidden.append(k) }
        }
        for s in LayoutSection.allCases {
            for k in current.keys(in: s) where seen.insert(k).inserted {
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
        return l.normalizedHideUnits().layout
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
public struct ArrangeTracker: Equatable, Sendable {
    public static let timeout: TimeInterval = 90
    public static let timeoutText = "Arrange window timeout: the menu bar still does not match the layout after 90 s (the engine may still be working)"

    /// `awaitingStamp`: the drop's layout has been submitted but the engine has not yet reported the revision it produced
    /// (`stamp`); such an entry is never judged. `ticket` identifies the submission.
    public struct Entry: Equatable, Sendable {
        public var dropSequence: Int
        public var since: Date
        public var awaitingStamp: Bool = false
        public var ticket: Int = 0
    }
    private var nextTicket = 0
    public private(set) var entries: [ItemKey: Entry] = [:]
    public private(set) var timedOut: Set<ItemKey> = []
    private var lastUpdate: Date?
    public init() {}

    public var awaiting: Set<ItemKey> { Set(entries.keys) }
    public var isEmpty: Bool { entries.isEmpty }

    /// Keys whose current engine status predates their judging pass.
    /// While the observation is unsettled (gdu.46) no engine status can be trusted (an unsettled pass refreshes none), so every
    /// tracked key is suppressed.
    public func suppressed(passSequence: Int, observationSettled: Bool = true) -> Set<ItemKey> {
        if !observationSettled { return Set(entries.keys) }
        return Set(entries.filter { $0.value.awaitingStamp || passSequence <= $0.value.dropSequence }.keys)
    }

    /// Records a submitted move (unit siblings together). Re-recording a key restarts its wait.
    ///
    /// `awaitingStamp: true` (a drop that goes through `LayoutEngine.setLayout`): the entry is not judged until `stamp(ticket:...)`
    /// supplies the engine's `passesStartedAtRevision` for the revision this drop produced (gdu.48). The returned ticket names
    /// this submission. Without it, `passesStarted` is the stamp (an action that publishes no layout).
    @discardableResult
    public mutating func record(_ keys: [ItemKey], passesStarted: Int, now: Date, awaitingStamp: Bool = false) -> Int {
        nextTicket += 1
        for k in keys {
            entries[k] = Entry(dropSequence: passesStarted, since: now, awaitingStamp: awaitingStamp, ticket: nextTicket)
            timedOut.remove(k)
        }
        return nextTicket
    }

    public mutating func retry(passesStarted: Int, now: Date) {
        for k in entries.keys { entries[k] = Entry(dropSequence: passesStarted, since: now, ticket: entries[k]?.ticket ?? 0) }
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
                                showHiddenSection: Bool, now: Date, observationSettled: Bool = true) -> [String] {
        defer { lastUpdate = now }
        // An unsettled observation judges nothing (no check mark, no failure) and does not run the timeout clock: the wait
        // is extended by the time spent unsettled. `passSequence` still advances (every started pass finishes), so judging
        // resumes at the next settled state with `passSequence > dropSequence`.
        guard observationSettled else {
            if let last = lastUpdate { let dt = now.timeIntervalSince(last); for k in entries.keys { entries[k]?.since += dt } }
            return []
        }
        var log: [String] = []
        for (k, e) in entries {
            guard layout.section(of: k) != nil else { entries[k] = nil; timedOut.remove(k); continue }
            let dt = now.timeIntervalSince(e.since)
            if !e.awaitingStamp, passSequence > e.dropSequence {
                switch perItem[k] {
                case .failed(let err)?:
                    entries[k] = nil; timedOut.remove(k)
                    log.append("\(k) FAILED \(String(format: "%.1f", dt))s after the drop: \(ArrangeSections.describe(err))")
                    continue
                case .unsupported(let r)?:
                    entries[k] = nil; timedOut.remove(k)
                    log.append("\(k) unsupported \(String(format: "%.1f", dt))s after the drop: \(r)")
                    continue
                case let st? where st == .inPlace || st == .notFitting:
                    if ArrangeSections.placementMatches(k, layout: layout, observed: observed, showHiddenSection: showHiddenSection) {
                        entries[k] = nil; timedOut.remove(k)
                        log.append("\(k) verified in place \(String(format: "%.1f", dt))s after the drop (observed order matches)")
                        continue
                    }
                default: break
                }
            }
            if dt > Self.timeout, timedOut.insert(k).inserted { log.append("\(k) NOT applied after \(Int(Self.timeout))s") }
        }
        return log
    }
}
