import Foundation
import DecisionCore

/// ejb.16 (Wiring 4): what the engine publishes for display after the core judged a PASS read: the core's `Status`, one `Row` and optional
/// `RowNote` per record key, and how many items macOS folds behind « (for the bar-full text). Poll reads never change it.
public struct CoreDisplay: Equatable, Sendable {
    public var status: Status
    public var rows: [ItemKey: Row]
    public var notes: [ItemKey: RowNote]
    public var pileCount: Int
    /// ejb.20: the key whose engine move waits for Re-apply (the core status is `differs(needsReapply)`), mapped to the engine's key.
    public var reapplyKey: ItemKey?
    /// ejb.9 (Lean `adoptProposal`): the record "Use the bar's current order" would save, in the core's record order (chevron and immovable keys are not in it).
    /// Non-nil only when the core's verdict of the last pass read is `differs`. The decision is Lean's; see `CoreAdoption`.
    public var adoption: [ItemKey]?
    public init(status: Status, rows: [ItemKey: Row] = [:], notes: [ItemKey: RowNote] = [:], pileCount: Int = 0, reapplyKey: ItemKey? = nil, adoption: [ItemKey]? = nil) {
        self.status = status; self.rows = rows; self.notes = notes; self.pileCount = pileCount; self.reapplyKey = reapplyKey; self.adoption = adoption
    }
}

/// Everything besides the core's `Status` that the bottom line says (wiring plan section 4, D7). Leaders come first and block "Menu bar matches";
/// notices come first but do not block it; trailers follow.
public struct CoreStatusContext: Equatable, Sendable {
    public var trusted = true
    public var conflicting: String?
    public var lastError: EngineError?
    public var userPaused = false
    public var pauseReason: String?
    public var adoptionPending = false
    public var handDragNotice: String?
    public var systemSettingsNotice: String?
    /// Items whose membership change failed (hide/show).
    public var failedMembership = 0
    /// Transient notices (reveal, new item, order note). Not leaders.
    public var notices: [String] = []
    public var movingName: String?
    public var pileCount = 0
    /// The display name of the item whose move waits for Re-apply (`differs(needsReapply)`).
    public var reapplyName: String?
    // D7 trailers
    public var pinnedDown = 0
    public var pollPaused: String?
    public var unsettledNotice: String?
    public init() {}

    /// Whether anything leads the status (D7 leaders): while true, "Menu bar matches" is never said.
    public var hasLeader: Bool {
        lastError != nil || userPaused || pauseReason != nil || adoptionPending || handDragNotice != nil || systemSettingsNotice != nil
            || failedMembership > 0 || !trusted || conflicting != nil
    }
}

/// The ONE renderer of the bottom line (D10): the Arrange window and the menu both call it.
public enum CoreStatusText {
    public static let matches = ArrangeSections.menuBarMatches
    public static let noMoveToMake = "Sommelier has no move to make right now"   // Lean: differs(plain) "carries the reason" (Honesty.userRetry_answers)

    public static func render(_ status: Status?, _ c: CoreStatusContext) -> String {
        if !c.trusted { return "Accessibility required" }
        if c.conflicting != nil { return "Bartender is running — paused" }
        var parts: [String] = c.notices
        if let e = c.lastError { parts.append(StatusLine.errorText(e)) }
        if c.userPaused { parts.append("Paused by you") }
        if let why = c.pauseReason { parts.append("Paused: \(why)") }
        if c.adoptionPending { parts.append(ArrangeSections.readingOrder) }
        if let n = c.handDragNotice { parts.append(n) }
        if let n = c.systemSettingsNotice { parts.append(n) }
        if c.failedMembership > 0 { parts.append("\(c.failedMembership) failed") }
        let leader = c.hasLeader
        switch status {
        case nil, .checking?: parts.append(ArrangeSections.checkingMenuBar)
        case .moving?: parts.append(c.movingName.map { "Moving \($0)…" } ?? "Moving…")
        case .matches?: if !leader { parts.append(matches) }
        case .matchesExcept(let ks)?: if !leader { parts.append("\(matches) except \(ks.count) unread") }
        case .differs(.stopped)?: parts.append(ArrangeBarState.stoppedWhileDifferingText)
        case .differs(.barFull)?: parts.append(ArrangeSections.barFullText(c.pileCount))
        case .differs(.needsReapply)?: parts.append(reapplyText(c.reapplyName))
        case .differs(.plain)?: parts.append(noMoveToMake)
        }
        if c.pinnedDown > 0 { parts.append(ArrangeSections.cannotPinDownText(c.pinnedDown)) }
        if let p = c.pollPaused { parts.append(p) }
        if let u = c.unsettledNotice { parts.append(u) }
        return parts.joined(separator: " · ")
    }

    /// ejb.20: the engine's next move needs the strip (it or its target is near the fold) and waits for Re-apply (Lean `differs (needsReapply k)`).
    public static func reapplyText(_ name: String?) -> String { "Re-apply to move \(name ?? "an item"): the move needs the « strip" }

    /// The context from the engine's published state: what Arrange AND the menu both render, so they cannot differ.
    @MainActor
    public static func context(state: EngineState, trusted: Bool, conflicting: String?, now: Date = Date()) -> CoreStatusContext {
        var c = CoreStatusContext()
        c.trusted = trusted; c.conflicting = conflicting; c.lastError = state.lastError
        c.userPaused = state.userPaused; c.pauseReason = state.pauseReason; c.adoptionPending = state.layout.pendingAdoption
        c.handDragNotice = state.handDragNotice; c.systemSettingsNotice = state.systemSettingsNotice
        c.failedMembership = state.perItem.values.filter { if case .failed = $0 { return true }; return false }.count
        c.notices = [state.revealNotice ?? ArrangeSections.revealSkipNotice(state: state),
                     state.inFlight != nil ? state.orderMoveNotice : nil, state.newItemNotice].compactMap { $0 }
        if let a = state.inFlight {
            let k: ItemKey
            switch a { case .move(let x, _), .hide(let x), .show(let x): k = x }
            c.movingName = RowNameRule.Namer(layout: state.layout, items: state.items).name(k)
        }
        c.pileCount = state.coreDisplay?.pileCount ?? 0
        if let k = state.coreDisplay?.reapplyKey { c.reapplyName = RowNameRule.Namer(layout: state.layout, items: state.items).name(k) }
        c.pinnedDown = state.perItem.values.filter { if case .unsupported(let r) = $0 { return r.hasPrefix(ArrangeSections.positionTimeoutPrefix) }; return false }.count
        c.pollPaused = ArrangeSections.pollPausedNames(suppression: state.pollSuppression, items: state.items, now: now).map { ArrangeSections.pollPausedText($0) }
        c.unsettledNotice = state.unsettledNotice
        return c
    }

    @MainActor
    public static func text(state: EngineState, trusted: Bool, conflicting: String?, now: Date = Date()) -> String {
        render(state.coreDisplay?.status, context(state: state, trusted: trusted, conflicting: conflicting, now: now))
    }
}

/// D9: the Lean row decides; Swift may refine the wording only within the same ok-class. D5 timeouts may only downgrade (ok to not ok).
public enum CoreRowRule {
    /// ok = tick, behind, notOnBar; not ok = moving, waiting, notWherePut, cannotTell.
    public static func isOK(_ r: Row) -> Bool {
        switch r { case .tick, .behind, .notOnBar: return true; case .moving, .waiting, .notWherePut, .cannotTell: return false }
    }
    public static func isOK(_ s: ArrangeBarState) -> Bool {
        switch s { case .matches, .behindChevron, .notOnBar: return true; default: return false }
    }
    /// The state the Lean row alone would show.
    public static func canonical(_ r: Row) -> ArrangeBarState {
        switch r {
        case .tick: return .matches
        case .behind: return .behindChevron
        case .notOnBar: return .notOnBar
        case .moving, .waiting: return .moving
        case .notWherePut, .cannotTell: return .notConfirmed
        }
    }
    /// `core` nil = the core made no claim about this key: nothing may be shown as ok.
    public static func reconcile(core: Row?, swift: ArrangeBarState, timedOut: Bool) -> ArrangeBarState {
        guard let core else { return isOK(swift) ? .notConfirmed : swift }
        let coreOK = isOK(core), swiftOK = isOK(swift)
        if coreOK == swiftOK { return swift }
        if coreOK, !swiftOK, timedOut { return swift }   // D5: a timeout downgrades
        return canonical(core)                            // Swift never upgrades, and never overrules the core's class otherwise
    }
    /// The note text beside a row that says "not where you put it".
    public static func text(_ n: RowNote) -> String {
        switch n {
        case .noMoveHelps: return "No single move of this item would improve the order"
        case .cantJudge: return "Sommelier can't yet see enough of the bar to place this item"
        case .noMoveHere: return "Sommelier has no move for this item right now"
        case .needsReapply: return "Re-apply to move this item: the move needs the « strip"
        }
    }
}
