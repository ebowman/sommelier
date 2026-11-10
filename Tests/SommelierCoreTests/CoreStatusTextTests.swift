import Foundation
import Testing
import DecisionCore
@testable import SommelierCore

// ejb.16 (Wiring 4): the core's status and rows reach the display through ONE renderer (D10), with D7 leaders/trailers and the D9 row rule.

private func key(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }

private let allStatuses: [Status?] = [nil, .moving, .matches, .matchesExcept([]), .matchesExcept([1, 2]), .differs(.stopped), .differs(.barFull), .differs(.plain), .checking]
private let allErrors: [EngineError?] = [nil, .permissionDenied, .conflictingManager("x"), .observe("o"), .stoppedAfterFailures(3),
                                         .batchDrift(expected: "e", observed: "o"), .batchFailed("b"), .decision("malformedInput")]

/// Every combination of the Swift contexts.
private func allContexts() -> [CoreStatusContext] {
    var out: [CoreStatusContext] = []
    for e in allErrors { for paused in [false, true] { for reason in [nil, "a menu is open"] as [String?] { for adopt in [false, true] {
    for hand in [nil, "Adopted your menu bar drag"] as [String?] { for ss in [nil, "Moved X to Hidden"] as [String?] { for failed in [0, 2] {
    for trusted in [true, false] { for conflict in [nil, "Bartender"] as [String?] { for notice in [[], ["New item: A placed in Visible"]] {
    for pinned in [0, 1] { for poll in [nil, "Polling paused"] as [String?] {
        var c = CoreStatusContext()
        c.lastError = e; c.userPaused = paused; c.pauseReason = reason; c.adoptionPending = adopt; c.handDragNotice = hand
        c.systemSettingsNotice = ss; c.failedMembership = failed; c.trusted = trusted; c.conflicting = conflict; c.notices = notice
        c.pinnedDown = pinned; c.pollPaused = poll; c.unsettledNotice = pinned == 1 ? "Unsettled" : nil; c.pileCount = 3; c.movingName = "Foo"
        out.append(c)
    } } } } } } } } } } } }
    return out
}

@Suite struct CoreStatusTextTests {
    @Test func menuBarMatchesOnlyForMatchesWithNoLeaderAndNoError() {
        var shown = 0
        for s in allStatuses { for c in allContexts() {
            let t = CoreStatusText.render(s, c)
            let isMatch: Bool = { if case .matches? = s { return true }; if case .matchesExcept? = s { return true }; return false }()
            let blocked = c.lastError != nil || c.hasLeader
            let says = t.contains("Menu bar matches")
            #expect(says == (isMatch && !blocked && c.trusted && c.conflicting == nil), "status \(String(describing: s)) ctx \(c) -> \(t)")
            if says { shown += 1 }
            if case .decision? = c.lastError { #expect(!says) }
        } }
        #expect(shown > 0)
    }

    @Test func wordingOfEachStatus() {
        let c = CoreStatusContext()
        var m = c; m.movingName = "Foo"; m.pileCount = 4
        #expect(CoreStatusText.render(.moving, m) == "Moving Foo…")
        #expect(CoreStatusText.render(.moving, c) == "Moving…")
        #expect(CoreStatusText.render(.matches, c) == "Menu bar matches")
        #expect(CoreStatusText.render(.matchesExcept([7, 8]), c) == "Menu bar matches except 2 unread")
        #expect(CoreStatusText.render(.differs(.stopped), c) == ArrangeBarState.stoppedWhileDifferingText)
        #expect(CoreStatusText.render(.differs(.barFull), m) == ArrangeSections.barFullText(4))
        #expect(CoreStatusText.render(.differs(.plain), c) == "Sommelier has no move to make right now")
        #expect(CoreStatusText.render(.checking, c) == ArrangeSections.checkingMenuBar)
        #expect(CoreStatusText.render(nil, c) == ArrangeSections.checkingMenuBar)
        var t = c; t.pinnedDown = 2; t.pollPaused = "P"; t.unsettledNotice = "U"
        #expect(CoreStatusText.render(.matches, t).hasPrefix("Menu bar matches · "))   // trailers follow and do not block
        var l = c; l.userPaused = true
        #expect(CoreStatusText.render(.matches, l) == "Paused by you")                  // a leader replaces the claim
    }

    @Test func rowNotesText() {
        #expect(CoreRowRule.text(.noMoveHelps) == "No single move of this item would improve the order")
        #expect(CoreRowRule.text(.cantJudge) == "Sommelier can't yet see enough of the bar to place this item")
        #expect(CoreRowRule.text(.noMoveHere) == "Sommelier has no move for this item right now")
    }

    /// The menu (`StatusLine.text(state:)`) and the Arrange window (`ArrangeViewModel.statusText`) both return `CoreStatusText.text(state:)`: equal for every status.
    @MainActor @Test func arrangeAndMenuTextEqualForEveryStatus() {
        for s in allStatuses {
            let st = EngineState()
            if let s { st.coreDisplay = CoreDisplay(status: s, pileCount: 3) }
            for (trusted, conflict) in [(true, nil), (true, "B"), (false, nil)] as [(Bool, String?)] {
                let menu = StatusLine.text(state: st, trusted: trusted, conflicting: conflict)
                let arrange = CoreStatusText.text(state: st, trusted: trusted, conflicting: conflict)
                #expect(menu == arrange)
                #expect(!menu.isEmpty)
            }
        }
    }

    @MainActor @Test func decisionErrorNeverShowsMatches() {
        let st = EngineState()
        st.coreDisplay = CoreDisplay(status: .matches)
        st.lastError = .decision("undecodableOutput")
        #expect(!StatusLine.text(state: st, trusted: true, conflicting: nil).contains("Menu bar matches"))
    }

    // MARK: D9

    private let allRows: [Row] = [.moving, .waiting, .tick, .behind, .notWherePut, .notOnBar, .cannotTell]
    private let allStates: [ArrangeBarState] = [.matches, .moving, .cannotPlace("r"), .notOnBar, .staleFrame, .behindChevron, .unreadAfterHandDrag, .notConfirmed]

    @Test func swiftNeverCrossesTheLeanOkClassExceptByTimeoutDowngrade() {
        for core in allRows + [nil] { for sw in allStates { for timedOut in [false, true] {
            let r = CoreRowRule.reconcile(core: core, swift: sw, timedOut: timedOut)
            let swOK = CoreRowRule.isOK(sw), rOK = CoreRowRule.isOK(r)
            guard let core else { #expect(!rOK, "no core claim must never show ok"); continue }
            let cOK = CoreRowRule.isOK(core)
            if !cOK { #expect(!rOK, "Swift upgraded \(core) via \(sw)") }                       // never an upgrade
            else if rOK != cOK { #expect(timedOut && !swOK, "only a D5 timeout may downgrade: \(core) \(sw)") }
            else { #expect(rOK) }
            if cOK && !timedOut { #expect(rOK) }
            if cOK == swOK { #expect(r == sw) }                                                  // same class: Swift's wording stands
        } } }
    }

    @Test func leanClassesAreTheBeadsClasses() {
        #expect(allRows.filter(CoreRowRule.isOK) == [.tick, .behind, .notOnBar])
        #expect(allStates.filter(CoreRowRule.isOK) == [.matches, .notOnBar, .behindChevron])
    }

    // MARK: publishing from PASS reads only

    private func read(_ kind: ReadKind, _ drawn: [Key], settled: Bool = true) -> Read {
        Read(kind: kind, chevron: .fresh, level: .complete, settled: settled, stripOpen: false, drawn: drawn, pile: [], folded: [], trusted: drawn, nearFold: [])
    }

    @Test func pollReadsLeaveTheDisplayUnchanged() throws {
        var d = CoreDriver()
        let ids = try ["a", "b", "c"].map { try d.keys.intern(key($0)) }
        _ = d.step(.userEdit(record: ids, moved: []), name: "userEdit", site: "test"); d.record = ids
        guard case .success = d.step(.read(read(.pass, ids)), name: "read", site: "test") else { Issue.record("step failed"); return }
        let shown = try #require(d.display)
        #expect(shown.rows.count == 3)
        for drawn in [ids, [ids[1], ids[0], ids[2]], [], [ids[2]]] {
            for settled in [true, false] {
                _ = d.step(.read(read(.poll, drawn, settled: settled)), name: "read", site: "test")
                #expect(d.display == shown, "a poll read changed the published display")
            }
        }
        // a pass read does change it
        _ = d.step(.read(read(.pass, [ids[1], ids[0], ids[2]])), name: "read", site: "test")
        #expect(d.display != shown)
    }

    // MARK: rows in Arrange come from the core; the old plan feeds nothing displayed

    @Test func arrangeRowsFollowTheCoreRowsAndIgnoreTheOldPlan() {
        let a = key("a"), b = key("b"), c = key("c")
        let layout = Layout.placedAll(visible: [a, b, c])
        let obs = ObservedOrder(onBar: [a, b, c], parked: [])
        var plan = PlanSummary(); plan.moving = [b]; plan.blocked = [c: a]   // the OLD plan says b moves and c waits: ignored
        let rows = ArrangeSections.make(observed: obs, layout: layout, items: [:], perItem: [a: .inPlace, b: .inPlace, c: .inPlace],
                                        capabilities: { _ in Capability(canMove: true, canHide: true) }, lastPlan: plan,
                                        coreRows: [a: .moving, b: .tick, c: .notWherePut], coreNotes: [c: .noMoveHelps]).visible.rows
        func state(_ k: ItemKey) -> ArrangeBarState? { rows.first { $0.key == k }?.barState }
        #expect(state(a) == .moving)          // the core upgrade of an ok-looking Swift row to "not ok" stands
        #expect(state(b) == .matches)         // the old plan's "moving" does not reach the display
        #expect(state(c) == .notConfirmed)
        #expect(rows.first { $0.key == c }?.stateNote == "No single move of this item would improve the order")
        // no core claim for a key: nothing may be shown as ok
        let none = ArrangeSections.make(observed: obs, layout: layout, items: [:], perItem: [:], capabilities: { _ in Capability(canMove: true, canHide: true) },
                                        coreRows: [:]).visible.rows
        #expect(none.allSatisfy { $0.barState != .matches })
    }
    // the position timeout (9o9.29) is a Swift timeout: a core tick may not upgrade it
    @Test func aPositionTimeoutIsNotUpgradedByACoreTick() {
        let a = key("a"), b = key("b"), c = key("c")
        let layout = Layout.placedAll(visible: [a, b, c])
        let obs = ObservedOrder(onBar: [a, b, c], parked: [])
        let timeout = ItemStatus.unsupported(ArrangeSections.positionTimeoutPrefix + " 30s")
        let rows = ArrangeSections.make(observed: obs, layout: layout, items: [:], perItem: [a: timeout, b: .inPlace, c: .inPlace],
                                        capabilities: { _ in Capability(canMove: true, canHide: true) },
                                        coreRows: [a: .tick, b: .tick, c: .tick]).visible.rows
        func state(_ k: ItemKey) -> ArrangeBarState? { rows.first { $0.key == k }?.barState }
        #expect(state(a) != .matches, "a core tick upgraded a position-timeout row")
        #expect(state(b) == .matches)
    }

    // the rows of an event cover the record that event installed (no one-event lag)
    @Test func aUserEditAddingAKeyGetsItsRowInTheSamePublication() throws {
        var d = CoreDriver()
        let ids = try ["a", "b", "c"].map { try d.keys.intern(key($0)) }
        let more = ids + [try d.keys.intern(key("d"))]
        _ = d.step(.userEdit(record: ids, moved: []), name: "userEdit", site: "test"); d.record = ids
        _ = d.step(.read(read(.pass, ids)), name: "read", site: "test")
        #expect(d.display?.rows[key("d")] == nil)
        _ = d.step(.userEdit(record: more, moved: []), name: "userEdit", site: "test")
        #expect(d.display?.rows[key("d")] == nil, "a non-read event computes nothing until the display is settled")
        d.settleDisplay()
        #expect(d.display?.rows[key("d")] != nil, "the new key has no row in the publication of the event that added it")
    }
}
