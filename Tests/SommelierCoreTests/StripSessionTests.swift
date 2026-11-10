import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

// 9o9.12: the actuator performs a move across (or near) the « fold inside a strip session: gate, click the chevron, fresh scan,
// drag with every frame real, click the chevron again. A tiny menu bar world with a collapsible strip.

private func key(_ n: String) -> ItemKey { .status(ownerKey: "app.\(n)", autosaveName: n) }
private let chev = "«"

private final class StripWorld: ActuatorPlatform, @unchecked Sendable {
    /// Left to right: the pile (behind the chevron), the chevron, the drawn items.
    var all: [String]
    var expanded = false
    var clock = Date(timeIntervalSince1970: 1000)
    var events: [String] = []               // "open", "close", "drag"
    var dragWhileCollapsed = false
    var dragTargets: [CGFloat] = []
    var openClicksWork = true, closeClicksWork = true
    var dragScript: [Bool] = []             // true = the drag applies, false = it does nothing; empty = applies
    var blocking: String?
    var buttons = 0
    var pressedClicks = 0
    var afterDrag: (() -> Void)?            // runs once after a drag is posted (the world changing under the actuator)
    var frameOverride: [String: CGRect] = [:]
    var windowGrowth = false                // 9o9.19: the owner's AX window count grows around a drag (the strip overlay appearing)
    var otherAppMenu = false                // 9o9.19: a pop-up window of ANOTHER app is on screen
    var probes = 0
    var escapes = 0
    var carried: Set<String> = []           // 9o9.23: names whose frame is a carried (stale) one while the strip is collapsed
    var carriedOpen: Set<String> = []       // ... and while it is open

    init(pile: [String], drawn: [String]) { all = pile + [chev] + drawn }

    func frames() -> [(name: String, frame: CGRect)] {
        let ci = all.firstIndex(of: chev)!
        var out: [(String, CGRect)] = []
        for (i, n) in all.enumerated() {
            if n == chev { out.append((n, CGRect(x: expanded ? 270 + CGFloat(i) * 40 : 795, y: 0, width: 17, height: 24))); continue }
            if i < ci { out.append((n, expanded ? CGRect(x: 270 + CGFloat(i) * 40, y: 0, width: 30, height: 24)
                                                : CGRect(x: 770 + CGFloat(i) * 2, y: 0, width: 30, height: 24))) }
            else { out.append((n, CGRect(x: (expanded ? 270 + CGFloat(ci) * 40 + 30 : 830) + CGFloat(i - ci - 1) * 40, y: 0, width: 30, height: 24))) }
        }
        return out.map { ($0.0, frameOverride[$0.0] ?? $0.1) }
    }
    func snapshot() -> MenuBarSnapshot {
        let items = frames().map { f -> MenuBarItem in
            var i = MenuBarItem(ownerPID: pid_t(abs(f.name.hashValue % 30000) + 100), ownerBundleID: "app.\(f.name)", ownerName: f.name, title: "",
                                axDescription: "", axIdentifier: f.name == chev ? "" : f.name, frame: f.frame, source: .appExtras, isOnMenuBar: true,
                                isOverflowChevron: f.name == chev, joinEvidence: .identifier)
            if f.name == chev { i.stripExpanded = expanded }
            if (expanded ? carriedOpen : carried).contains(f.name) { i.stale = true }
            return i
        }
        return MenuBarSnapshot(items: SystemOverflow.mark(items), capturedAt: clock)
    }
    func scanVisible() async -> MenuBarSnapshot { snapshot() }
    func scan() async -> MenuBarSnapshot { var s = snapshot(); s.hostedLayout = []; return s }

    func accessibilityTrusted() -> Bool { true }
    func pressedMouseButtons() -> Int { buttons }
    func conflictingManager() -> String? { nil }
    func resolve(_ s: MenuBarSnapshot) -> [ResolvedItem] {
        s.items.map { ResolvedItem(item: $0, key: $0.isOverflowChevron ? .module(name: MenuBarItem.overflowChevronName) : key($0.ownerName), confidence: .exact) }
    }
    func trackedKey(for item: ResolvedItem) -> String? { "tracked.\(item.item.ownerName)" }
    func drag(itemFrame: CGRect, toX: CGFloat, steps: Int) async throws -> Date {
        events.append("drag"); dragTargets.append(toX)
        if !expanded { dragWhileCollapsed = true }
        let apply = dragScript.isEmpty ? true : dragScript.removeFirst()
        if apply {
            let f = frames()
            let name = f.first { $0.frame.midX == itemFrame.midX }!.name
            let crossed = f.filter { $0.name != name && $0.frame.midX < toX }.count
            all.removeAll { $0 == name }
            all.insert(name, at: crossed)
        }
        if let h = afterDrag { afterDrag = nil; h() }
        return clock
    }
    func menuProbe(for item: MenuBarItem) -> MenuProbe { probes += 1; return MenuProbe(hasMenu: false, windowCount: windowGrowth ? probes : 0) }
    func menuOpenByAnotherApp() -> Bool { otherAppMenu }
    func pressEscape() { escapes += 1 }
    func readOrderStore() throws -> [String: Double] { [:] }
    func writeOrderStore(_ updates: [String: Double], allowModules: Bool) throws {}
    func waitForOrderStoreQuiet() async {}
    func writeAllowed(_ changes: [String: Bool]) throws {}
    func readAllowed(_ keys: [String]) throws -> [String: Bool] { [:] }
    var liveHideShowAvailable: Bool { false }
    func setAllowedLive(_ changes: [String: Bool]) throws {}
    func restartAgent(timeout: TimeInterval, expectedChange: Int) async -> AgentRestartOutcome { AgentRestartOutcome(recovered: true, elapsedMS: 1) }
    func sleep(_ seconds: TimeInterval) async { clock = clock.addingTimeInterval(seconds) }
    func now() -> Date { clock }

    func overflowProbe() async -> OverflowProbe? {
        let f = frames()
        return OverflowProbe(chevron: f.first { $0.name == chev }!.frame, expanded: expanded, hosted: f.filter { $0.name != chev }.map(\.frame))
    }
    func clickChevron(at point: CGPoint) -> Bool {
        guard frames().first(where: { $0.name == chev })!.frame.insetBy(dx: -2, dy: -2).contains(point) else { return true }   // a click elsewhere: nothing
        if expanded { events.append("close"); if closeClicksWork { expanded = false } }
        else { events.append("open"); if openClicksWork { expanded = true } }
        return true
    }
    func interactionBlockingReason() -> String? { blocking }
}

private func actuator(_ w: StripWorld, fallback: Bool = true) -> LiveActuator {
    var c = LiveActuator.Config()
    c.allowFallback = fallback
    return LiveActuator(platform: w, config: c)
}

private func names(_ w: StripWorld) -> [String] { w.all }

@Test func aPullOutOpensTheStripDragsInsideItAndClosesIt() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])
    #expect(!w.expanded && !w.dragWhileCollapsed)
    #expect(names(w).firstIndex(of: "X2")! == names(w).firstIndex(of: "A")! + 1)
    let trace = await a.trace
    #expect(trace.contains { $0.hasPrefix("phase strip: open t=") })
    #expect(trace.contains { $0.hasPrefix("phase strip: closed t=") })
}

@Test func aMoveWhoseTargetIsBehindTheChevronIsRefusedWithoutAStripSession() async {
    // gdu.134 rule 1: the former push-in. Nothing is aimed at a folded key: no chevron click, no drag.
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    let r = await a.move(key("A"), relation: .before(key("X1")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected a refusal, got \(r)"); return }
    #expect(why.contains("nothing is aimed at a folded key") && r.error?.isOverflowRefusal == true)
    #expect(w.events.isEmpty)
    #expect(!(await a.trace).contains { $0.hasPrefix("strip: needed") })
    #expect(!w.expanded)
}

@Test func aFailedDragInTheStripStillClosesItAndUsesOneSession() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.dragScript = [false, false]
    let r = await actuator(w, fallback: false).move(key("X2"), relation: .after(key("A")))
    #expect(!r.isVerified)
    #expect(w.events.filter { $0 == "open" }.count == 1)
    #expect(w.events.filter { $0 == "close" }.count == 1)
    #expect(w.events.first == "open" && w.events.last == "close")
    #expect(!w.expanded)
}

@Test func aMoveInsideTheDrawnRegionAwayFromTheFoldOpensNoStrip() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C", "D", "E"])
    let r = await actuator(w).move(key("D"), relation: .after(key("E")))
    #expect(r.isVerified)
    #expect(w.events == ["drag"])
}

@Test func aNonCrossingMoveTouchingTheChurnZoneIsAlsoAStripSession() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    await a.setChurnZone([key("A")])
    let r = await a.move(key("C"), relation: .before(key("A")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])
    #expect(!w.expanded)
}

@Test func aStripTheUserOpenedIsDraggedInAndLeftOpen() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.expanded = true
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.events == ["drag"])
    #expect(w.expanded)
}

@Test func aStaleChurnZoneNeverOpensOrClosesAStripTheUserHasOpen() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.expanded = true
    let a = actuator(w)
    await a.setChurnZone([key("X2"), key("A")])      // a stale zone: with an expanded snapshot it must not matter
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified && w.events == ["drag"] && w.expanded)
}

@Test func anExpansionFailureReturnsMechanismFailedWithoutDragging() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.openClicksWork = false
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected mechanismFailed, got \(r)"); return }
    #expect(why == "could not open the « strip")
    #expect(!w.events.contains("drag"))
    #expect(w.events == ["open"])
}

@Test func aCollapseFailureKeepsTheResultAndNotesTheStripStillExpanded() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.closeClicksWork = false
    let a = actuator(w)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)                                    // the drag was verified on the expanded observation
    #expect(w.events == ["open", "drag", "close", "close"])  // two closing tries, no more
    #expect(w.expanded)
    #expect(await a.trace.contains { $0.contains("overflowStripStillExpanded") })
}

@Test func theInteractionGateIsAskedBeforeTheChevronIsClicked() async {
    for (why, setup) in [("a menu is open", { (w: StripWorld) in w.blocking = "a menu is open" }),
                         ("the mouse button is down", { (w: StripWorld) in w.buttons = 1 })] {
        let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
        setup(w)
        let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
        #expect(r.error == .userBusy, "\(why)")
        #expect(w.events.isEmpty, "\(why)")
    }
}

@Test func aDrawnSubjectAfterTheLastPileKeyIsRefusedBeforeAnyStripSession() async {
    // Y (drawn) after X2, the LAST pile key (its drop would land on the chevron): gdu.134 refuses it outright, a folded target.
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let r = await actuator(w, fallback: false).move(key("B"), relation: .after(key("X2")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected a refusal, got \(r)"); return }
    #expect(why.contains("nothing is aimed at a folded key"))
    #expect(w.events.isEmpty)
    #expect(!w.expanded)
}

@Test func aCrossFoldDragThatDoesNotHoldPostsOneDragAndReturnsTheHoldFailure() async {
    // gdu.134 rule 3: no retry drag across the fold; the failure is the bar-level "did not hold" outcome.
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.dragScript = [false, true]       // the first drag does nothing; a retry WOULD apply, and must not be posted
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    guard case .failed(let e, _) = r else { Issue.record("expected failed, got \(r)"); return }
    #expect(e.isStripMoveDidNotHold && e.isStripHoldFailure)
    #expect(w.events == ["open", "drag", "close"])
    #expect(w.dragTargets.count == 1 && !w.expanded)
}

@Test func aSecondAttemptIsRefusedWhenTheSubjectFoldedAfterTheFirstDragFailed() async {
    let w = StripWorld(pile: [], drawn: ["A", "B", "C", "D", "E", "F", "G"])
    w.dragScript = [false]
    w.afterDrag = { w.all = ["D", chev, "A", "B", "C", "E", "F", "G"] }   // macOS folds D behind the chevron
    let r = await actuator(w).move(key("D"), relation: .after(key("E")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected mechanismFailed, got \(r)"); return }
    #expect(why.contains("folded"))
    #expect(w.events == ["drag"])              // no second drag from the stacked pile frame
}

@Test func aSecondAttemptIsRefusedWhenTheStripClosedBetweenAttempts() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.dragScript = [false]
    w.afterDrag = { w.expanded = false }       // the strip closes under the session
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected mechanismFailed, got \(r)"); return }
    #expect(why == ActuationError.stripMoveDidNotHoldMessage)   // gdu.134: the one posted drag did not hold; no second attempt
    #expect(w.events.filter { $0 == "drag" }.count == 1)
    #expect(w.events.filter { $0 == "open" }.count == 1)
    #expect(!w.expanded)
}

@Test func aDrawnSubjectIsRefusedInsideTheSessionWhenTheStripClosesAfterAttempt1() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.dragScript = [false]
    w.afterDrag = { w.expanded = false }       // the strip closes under the session after attempt 1
    let a = actuator(w)
    let r = await a.move(key("X1"), relation: .after(key("B")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected mechanismFailed, got \(r)"); return }
    #expect(why == ActuationError.stripMoveDidNotHoldMessage)   // gdu.134: one drag, no re-plan, the hold failure
    let trace = await a.trace
    #expect(w.events.filter { $0 == "drag" }.count == 1)
    // the world closed the strip itself, so the session's close finds it collapsed: no click, and the trace says so
    #expect(w.events.filter { $0 == "close" }.isEmpty)
    #expect(trace.contains("phase strip: already closed"))
    #expect(!trace.contains { $0.hasPrefix("phase strip: closed t=") })
}

@Test func anOpenStripWithIdenticalFreshFramesIsRefusedForOverlap() async {
    let w = StripWorld(pile: [], drawn: ["A", "B", "C", "D"])
    w.expanded = true
    let fa = w.frames().first { $0.name == "A" }!.frame
    w.frameOverride["B"] = fa                  // two fresh items with the same frame
    let a = actuator(w)
    let r = await a.move(key("A"), relation: .after(key("D")))
    guard case .failed(.mechanismFailed(let why), _) = r else { Issue.record("expected mechanismFailed, got \(r)"); return }
    #expect(why.contains("not trustworthy"))
    #expect(!w.events.contains("drag"))
}


// MARK: 9o9.19: the fold rule verifies a crossing; the expanded strip is not a menu; a re-plan never aims at the chevron

private func actuator(_ w: StripWorld, record: [String]) async -> LiveActuator {
    let a = actuator(w, fallback: false)
    await a.setRecordOrder(record.map(key))
    return a
}

/// The live 17:41 shape: Jump (in the pile) goes after KYA (first drawn); macOS re-folds by width and KYA falls into the pile.
private func refoldWorld() -> StripWorld {
    let w = StripWorld(pile: ["Jump"], drawn: ["KYA", "B"])
    w.afterDrag = { w.all = ["KYA", chev, "Jump", "B"] }
    return w
}

@Test func aCrossingWhoseTargetRefoldsIntoThePileIsVerifiedByTheFoldRuleAfterTheStripCloses() async {
    let w = refoldWorld()
    let a = await actuator(w, record: ["KYA", "Jump", "B"])
    let r = await a.move(key("Jump"), relation: .after(key("KYA")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])   // one session, one drag, no second attempt
    #expect(!w.expanded)
    let trace = await a.trace
    #expect(trace.contains { $0.contains("fold rule:") && $0.contains("verified on the settled read after the strip closed") })
    #expect(!trace.contains { $0.contains("drop refused") })
}

@Test func theFoldRuleReadIsTakenOnTheOpenStripWhenTheUserHadItOpen() async {
    let w = refoldWorld()
    w.expanded = true
    let a = await actuator(w, record: ["KYA", "Jump", "B"])
    let r = await a.move(key("Jump"), relation: .after(key("KYA")))
    #expect(r.isVerified)
    #expect(w.events == ["drag"] && w.expanded)       // left open, nothing clicked
}

@Test func theFoldRuleIsNotSatisfiedByASubjectLeftBehindTheChevron() async {
    // The drag did nothing: Jump stays in the pile, so the rule cannot verify it.
    let w = StripWorld(pile: ["Jump"], drawn: ["KYA", "B"])
    w.dragScript = [false, false]
    let r = await actuator(w, record: ["KYA", "Jump", "B"]).move(key("Jump"), relation: .after(key("KYA")))
    #expect(!r.isVerified)
    #expect(w.events.filter { $0 == "open" }.count == 1 && w.events.filter { $0 == "close" }.count == 1)
}

@Test func aTargetThatReFoldedIsNeverReplacedByASubstituteTarget() async {
    // gdu.134 rule 2: the 08:21:53 shape. The target re-folds after the drag; K2 (record-left of Jump) is drawn, but no second drag is posted.
    let w = StripWorld(pile: ["Jump"], drawn: ["KYA", "K2"])
    w.afterDrag = { w.all = ["KYA", chev, "Jump", "K2"] }
    let a = await actuator(w, record: ["K2", "KYA", "Jump"])
    let r = await a.move(key("Jump"), relation: .after(key("KYA")))
    guard case .failed(let e, _) = r else { Issue.record("expected failed, got \(r)"); return }
    #expect(e.isStripMoveDidNotHold)
    #expect(w.dragTargets.count == 1)
    #expect(w.events == ["open", "drag", "close"])
    #expect(!(await a.trace).contains { $0.contains("aiming after") })
}

@Test func aReplanWithNoDrawnKeyToStandInEndsHonestlyWithoutAnotherDrag() async {
    let w = StripWorld(pile: ["Jump"], drawn: ["KYA", "X"])
    w.afterDrag = { w.all = ["KYA", chev, "X", "Jump"] }   // X belongs right of Jump but is drawn left of it: the rule fails
    let a = await actuator(w, record: ["KYA", "Jump", "X"])
    let r = await a.move(key("Jump"), relation: .after(key("KYA")))
    #expect(!r.isVerified)
    #expect(w.dragTargets.count == 1)
    #expect(w.events == ["open", "drag", "close"])
    #expect((await a.trace).contains { $0.contains("no substitute target") })
}

@Test func aBeforeSpelledPullOutOpensTheStripDragsAndVerifiesByTheFoldRuleWithTheUntrustedKeyDrawnLeftOfTheSubject() async {
    // 9o9.28: record [TM, Jump, Gate]; TM is drawn (untrusted for planning), Jump is in the pile: Jump .before(Gate).
    let w = StripWorld(pile: ["Jump"], drawn: ["TM", "Gate"])
    let a = await actuator(w, record: ["TM", "Jump", "Gate"])
    let r = await a.move(key("Jump"), relation: .before(key("Gate")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])
    #expect(!w.expanded && !w.dragWhileCollapsed)
    let chevronFrame = w.frames().first { $0.name == chev }!.frame
    #expect(w.dragTargets.allSatisfy { !chevronFrame.insetBy(dx: -2, dy: 0).contains(CGPoint(x: $0, y: chevronFrame.midY)) })
    #expect(w.all.firstIndex(of: "TM")! < w.all.firstIndex(of: "Jump")!)
    #expect(w.all.firstIndex(of: "Jump")! < w.all.firstIndex(of: "Gate")!)
    #expect(!(await a.trace).contains { $0.contains("drop refused") })
}

@Test func theExpandedStripOverlayIsNeverAMenuInsideASession() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.windowGrowth = true            // the owner's window count grows around the drag: the strip overlay, not a menu
    let a = actuator(w)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.escapes == 0)
    let trace = await a.trace
    #expect(!trace.contains { $0.contains("menu opened") })
    #expect(trace.contains { $0.contains("not a menu; ignored") })
}

@Test func aPopUpOfAnotherAppInsideASessionIsStillAMenu() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.windowGrowth = true
    w.otherAppMenu = true
    let a = actuator(w)
    _ = await a.move(key("X2"), relation: .after(key("A")))
    #expect(w.escapes >= 1)
    #expect((await a.trace).contains { $0.contains("menu opened; Escape") })
}

@Test func aStripTheUserOpenedIsNeverAMenuEither() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.expanded = true
    w.windowGrowth = true
    let a = actuator(w)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.events == ["drag"] && w.escapes == 0)
    #expect(!(await a.trace).contains { $0.contains("menu opened") })
}

@Test func aPopUpOfAnotherAppWithTheUsersStripOpenIsStillAMenu() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.expanded = true
    w.windowGrowth = true
    w.otherAppMenu = true
    let a = actuator(w)
    _ = await a.move(key("X2"), relation: .after(key("A")))
    #expect(w.escapes >= 1)
    #expect((await a.trace).contains { $0.contains("menu opened; Escape") })
}

@Test func theOrderStoreFallbackNeverRunsWithTheUsersStripOpen() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.expanded = true
    w.dragScript = [false, false, false, false]
    let a = actuator(w, fallback: true)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(!r.isVerified)
    #expect(!(await a.trace).contains { $0.contains("fallback: order store") })
}

@Test func theFoldVerdictRule() {
    func r(_ n: String, _ x: CGFloat, chevron: Bool = false) -> ResolvedItem {
        let i = MenuBarItem(ownerPID: 1, ownerBundleID: nil, ownerName: n, title: "", axDescription: "", axIdentifier: n,
                            frame: CGRect(x: x, y: 0, width: 20, height: 24), source: .appExtras, isOnMenuBar: true, isOverflowChevron: chevron, joinEvidence: .identifier)
        return ResolvedItem(item: i, key: chevron ? .module(name: MenuBarItem.overflowChevronName) : key(n), confidence: .exact)
    }
    let read = [r("P", 100), r(chev, 120, chevron: true), r("S", 150), r("D", 180)]
    #expect(ActuationVerifier.foldVerdict(subject: key("S"), record: ["P", "S", "D"].map(key), resolved: read).ok)
    #expect(!ActuationVerifier.foldVerdict(subject: key("S"), record: ["D", "S"].map(key), resolved: read).ok)   // D belongs left, is drawn right
    #expect(!ActuationVerifier.foldVerdict(subject: key("P"), record: ["P", "S"].map(key), resolved: read).ok)   // subject behind the chevron
    #expect(ActuationVerifier.foldVerdict(subject: key("S"), record: ["S", "P"].map(key), resolved: read).ok)   // gdu.144: a pile key is ignored wherever the record puts it
    #expect(ActuationVerifier.foldVerdict(subject: key("S"), record: ["Gone", "S", "D"].map(key), resolved: read).ok)   // off-bar keys are ignored
}

@Test func aCarriedPileSubjectOpensTheStripAndDragsOnceTheOpenReadIsFresh() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.carried = ["X2"]
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])
    #expect(!w.dragWhileCollapsed && !w.expanded)
}

@Test func aPileSubjectStillStaleOnTheOpenStripReadIsRefusedWithOneCloseAndNoDrag() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.carried = ["X2"]; w.carriedOpen = ["X2"]
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    guard case .failed = r else { Issue.record("expected failed, got \(r)"); return }
    #expect(w.events == ["open", "close"])
    #expect(!w.expanded)
}

@Test func aCarriedPileTargetIsRefusedWithoutAStripSession() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.carried = ["X1"]
    let r = await actuator(w).move(key("A"), relation: .before(key("X1")))
    #expect(!r.isVerified && r.error?.isOverflowRefusal == true)   // gdu.134: a folded target is refused, whatever its frame
    #expect(w.events.isEmpty)
    #expect(!w.dragWhileCollapsed)
}

@Test func aPileTargetStillStaleOnTheOpenStripReadIsRefusedWithOneCloseAndNoDrag() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.carried = ["X1"]; w.carriedOpen = ["X1"]
    let r = await actuator(w).move(key("A"), relation: .before(key("X1")))
    guard case .failed = r else { Issue.record("expected failed, got \(r)"); return }
    #expect(w.events.isEmpty)   // gdu.134: refused before any strip session
}

// MARK: - 9o9.29: a `.before` target that is the first drawn key (right of the chevron)

@Test func aBeforeTargetThatIsTheFirstDrawnKeyDropsJustRightOfTheChevronNotOnIt() async throws {
    let w = StripWorld(pile: ["Jump"], drawn: ["B", "C"])
    let a = await actuator(w, record: ["Jump", "B", "C"])
    let r = await a.move(key("Jump"), relation: .before(key("B")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])           // dragged once: no refusal, no re-plan
    // The strip is open during the drag: the chevron spans 310..327, B starts at 340 (midX 355). The drop is the chevron's maxX + 2.
    #expect(w.dragTargets.count == 1)
    let first = try #require(w.dragTargets.first)
    #expect(first == 329)
    #expect(!(await a.trace).contains { $0.contains("drop refused") })
}

@Test func aBeforeTargetThatIsNotTheFirstDrawnKeyKeepsTheGenericDropX() async {
    let w = StripWorld(pile: ["Jump"], drawn: ["B", "C"])
    let a = await actuator(w, record: ["Jump", "B", "C"])
    _ = await a.move(key("Jump"), relation: .before(key("C")))
    #expect(w.dragTargets.count >= 1)
    #expect(w.dragTargets[0] != 329)
}

// MARK: - gdu.129: an open strip that cannot place the subject is a bar-level failure, with ONE diagnostic line

@Test func aSubjectNotPlaceableInTheOpenStripIsABarLevelFailureWithOneDiagnosticLine() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.carried = ["X2"]; w.carriedOpen = ["X2"]
    let a = actuator(w)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    guard case .failed(let e, _) = r else { Issue.record("expected failed, got \(r)"); return }
    #expect(e.isStripUnplaceable && e == .mechanismFailed(ActuationError.stripUnplaceableMessage))
    #expect(w.events == ["open", "close"])
    let lines = await a.trace.filter { $0.hasPrefix("strip: subject not placeable inside the open strip:") }
    #expect(lines.count == 1)
    #expect(lines[0].contains("stale=true") && lines[0].contains("join=identifier") && lines[0].contains("hosted left of the chevron"))
}

// MARK: gdu.144 B4: an engine-initiated move (setSingleDrag) never opens the strip

@Test func anEngineInitiatedChurnZoneMoveClicksNoChevronAndPostsNoDrag() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    await a.setChurnZone([key("A")])
    await a.setEngineInitiated(true)
    let r = await a.move(key("C"), relation: .before(key("A")))
    #expect(!r.isVerified && r.error?.isOverflowRefusal == true)   // a refusal: the engine reads it as a skip, never a strike
    #expect(w.events.isEmpty)   // no "open", no "drag", no "close": zero chevron clicks
    // the same move is the user's own drop (flag off): the strip session is allowed
    await a.setEngineInitiated(false)
    let u = await a.move(key("C"), relation: .before(key("A")))
    #expect(u.isVerified && w.events == ["open", "drag", "close"])
}

@Test func anEngineInitiatedPullOutClicksNoChevronEither() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    await a.setEngineInitiated(true)
    let r = await a.move(key("X2"), relation: .after(key("A")))
    #expect(!r.isVerified && w.events.isEmpty)
}

// MARK: gdu.144 D2: the REAL engine on the REAL actuator (fake platform), no user input: zero chevron clicks, whatever the engine read

private struct WorldObserver144: MenuBarObserver {
    let w: StripWorld
    func observe() async throws -> [ResolvedItem] { w.resolve(w.snapshot()) }
}
/// The engine's read has NO chevron at all (never seen one), while the actuator's own scan of the same world has one.
private struct NoChevObserver144: MenuBarObserver {
    let names: [String]
    func observe() async throws -> [ResolvedItem] {
        names.enumerated().map { (i, n) in
            var it = MenuBarItem(ownerPID: pid_t(abs(n.hashValue % 30000) + 100), ownerBundleID: "app.\(n)", ownerName: n, title: "", axDescription: "", axIdentifier: n,
                                 frame: CGRect(x: 100 + CGFloat(i) * 50, y: 0, width: 30, height: 24), source: .appExtras, isOnMenuBar: true, isOverflowChevron: false, joinEvidence: .identifier)
            it.controlCenterAllowed = true
            return ResolvedItem(item: it, key: key(n), confidence: .exact)
        }
    }
}
private struct OpenCaps144: CapabilityProvider { func capability(for k: ItemKey) -> Capability { Capability(canMove: true, canHide: true) } }

@MainActor private func realEngine144(_ w: StripWorld, observer: any MenuBarObserver, record: [String]) async -> (LayoutEngine, EngineState) {
    let st = EngineState()
    var cfg = LayoutEngine.Config.plain(); cfg.maxOrderMovesPerPass = .max
    let e = LayoutEngine(observer: observer, actuator: actuator(w), store: InMemoryLayoutStore(Layout.placedAll(visible: record.map(key))), capabilities: OpenCaps144(), state: st,
                         resolveSnapshot: { s in w.resolve(s) }, sleep: { _ in }, log: { _ in }, config: cfg)
    await e.start()
    return (e, st)
}

@MainActor @Test func theRealEngineOnTheRealActuatorClicksNoChevronWithoutUserInput_chevronlessEngineRead() async {
    let w = StripWorld(pile: ["P1"], drawn: ["D1", "D2", "D3"])
    let (e, _) = await realEngine144(w, observer: NoChevObserver144(names: ["P1", "D1", "D2", "D3"]), record: ["D1", "D2", "D3", "P1"])
    for _ in 0..<10 { _ = await e.reconcileOnce() }
    #expect(!w.events.contains("open") && !w.events.contains("close"), "an engine-initiated move clicked the chevron: \(w.events)")
}

@MainActor @Test func theRealEngineOnTheRealActuatorClicksNoChevronWithoutUserInput_freshChevronAndAMismatchAtTheFold() async {
    let w = StripWorld(pile: ["P1", "P2"], drawn: ["D1", "D2", "D3", "D4"])
    // the record wants a folded key between drawn ones AND the first drawn keys swapped (churn zone): every move would need the strip
    let (e, _) = await realEngine144(w, observer: WorldObserver144(w: w), record: ["P1", "P2", "D2", "P2", "D1", "D3", "D4"].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
    for _ in 0..<12 { _ = await e.reconcileOnce() }
    #expect(!w.events.contains("open") && !w.events.contains("close"), "events=\(w.events)")
}

@MainActor @Test func theRealEngineMakesAUsersFoldDropWithExactlyOneSessionOnTheRealActuator() async {
    let w = StripWorld(pile: ["P1", "P2"], drawn: ["D1", "D2", "D3"])
    let (e, _) = await realEngine144(w, observer: WorldObserver144(w: w), record: ["P1", "P2", "D1", "D2", "D3"])
    _ = await e.reconcileOnce()
    #expect(w.events.isEmpty)
    // the user drops P1 and P2 (a two-key moved set) right of the fold line: ONE strip session, for the first key
    await e.setLayout(Layout.placedAll(visible: ["D1", "P1", "P2", "D2", "D3"].map(key)), moved: [key("P1"), key("P2")])
    for _ in 0..<6 { _ = await e.reconcileOnce() }
    #expect(w.events.filter { $0 == "open" }.count == 1 && w.events.filter { $0 == "drag" }.count == 1, "events=\(w.events)")
}

// MARK: ejb.13 (assumption 7): setStripAllowed(false) refuses a move that needs the strip, before any click or drag

@Test func aMoveThatNeedsTheStripIsRefusedWhenTheStripIsNotAllowedAndDefaultsToAllowed() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    await a.setChurnZone([key("A")])
    await a.setStripAllowed(false)
    let r = await a.move(key("C"), relation: .before(key("A")))
    #expect(!r.isVerified && r.error?.isStripNotAllowedRefusal == true)
    #expect(r.error?.isOverflowRefusal == false && r.error?.isStripHoldFailure == false)   // a distinct refusal reason
    #expect(w.events.isEmpty)                                                              // no click, no drag
    let pull = await a.move(key("X2"), relation: .after(key("A")))                         // a pull-out needs the strip too
    #expect(pull.error?.isStripNotAllowedRefusal == true && w.events.isEmpty)
    let plain = await a.move(key("B"), relation: .after(key("C")))                         // no strip needed: an ordinary drag still runs
    #expect(plain.isVerified && w.events == ["drag"])
    // allowed again: the same strip move runs its session
    await a.setStripAllowed(true)
    let ok = await a.move(key("C"), relation: .before(key("A")))
    #expect(ok.isVerified && w.events.suffix(3) == ["open", "drag", "close"])
}

@Test func stripAllowedDefaultsToTrueSoTodaysBehaviourIsUnchanged() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let a = actuator(w)
    await a.setChurnZone([key("A")])
    let r = await a.move(key("C"), relation: .before(key("A")))
    #expect(r.isVerified && w.events == ["open", "drag", "close"])
}
