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
    func menuProbe(for item: MenuBarItem) -> MenuProbe { MenuProbe(hasMenu: false, windowCount: 0) }
    func pressEscape() {}
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

@Test func aPushInAlsoRunsInsideOneSession() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let r = await actuator(w).move(key("A"), relation: .before(key("X1")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "close"])
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

@Test func aDropOnTheChevronIsRefusedAndTheStripStillCloses() async {
    // Y (drawn) after X2, the LAST pile key: moving left, the hover neighbour is the chevron itself.
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    let r = await actuator(w, fallback: false).move(key("B"), relation: .after(key("X2")))
    guard case .failed(.notVerified(_, let observed), _) = r else { Issue.record("expected notVerified, got \(r)"); return }
    #expect(observed.contains("chevron"))
    #expect(w.events == ["open", "close"])
    #expect(!w.expanded)
}

@Test func aSessionIsOneOrderMoveAndAtMostOneOpensPerCall() async {
    let w = StripWorld(pile: ["X1", "X2"], drawn: ["A", "B", "C"])
    w.dragScript = [false, true]       // the first attempt does nothing, the retry applies: still ONE open and ONE close
    let r = await actuator(w).move(key("X2"), relation: .after(key("A")))
    #expect(r.isVerified)
    #expect(w.events == ["open", "drag", "drag", "close"])
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
    #expect(why.contains("closed") || why.contains("not trustworthy"))   // refused either by the fold re-check or by the stacked-frame proof
    #expect(w.events.filter { $0 == "drag" }.count == 1)
    #expect(w.events.filter { $0 == "open" }.count == 1)
    #expect(!w.expanded)
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
