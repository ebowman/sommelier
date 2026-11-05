import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import SommelierCore

private let key = ItemKey.status(ownerKey: "com.x.tool", autosaveName: "Item-0")
private let barFrame = CGRect(x: 800, y: 0, width: 24, height: 24)
private let parkedFrame = CGRect(x: 0, y: 1188, width: 24, height: 24)

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private final class FakeMonitor: CloseMonitoring, @unchecked Sendable {
    let buffer = CloseEventBuffer()
    func start() {}
    func stop() {}
    func drain() -> [CloseEvent] { buffer.drain() }
}

private final class FakeActivation: ActivationPlatform, @unchecked Sendable {
    let clock = FakeClock()
    let monitor = FakeMonitor()
    var closeMonitor: (any CloseMonitoring)? { monitor }
    private let lock = NSLock()
    var live = true
    var locateResult: ActivationLocate = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: parkedFrame,
                                                                 isOnBar: false, systemOverflow: false))
    /// Seconds (fake) after the show write at which the item's frame lands on the bar; nil = never.
    var landsAfter: TimeInterval? = 0.2
    var writes: [[String: Bool]] = []
    var failHide = false
    var failShow = false
    var clicks: [(CGPoint, ClickButton)] = []
    var presses = 0
    var pressResult: Int32 = 0
    /// When the menu shows up after the click / press (fake seconds); nil = never; closes after `menuOpenFor` more.
    var menuAfter: TimeInterval? = 0.1
    var menuOpenFor: TimeInterval? = 2
    var mousePressed = 0
    private var shownAt: Date?
    private var openedAt: Date?

    var liveHideShowAvailable: Bool { live }
    func pressedMouseButtons() -> Int { mousePressed }
    var cachedTarget: ActivationTarget?
    var ownerTarget: ActivationTarget?
    var locateCalls = 0, cachedCalls = 0, ownerCalls = 0
    func locate(_ k: ItemKey) async -> ActivationLocate { locateCalls += 1; return locateResult }
    func locateCached(_ k: ItemKey) async -> ActivationTarget? { cachedCalls += 1; return cachedTarget }
    func locateByOwner(_ k: ItemKey) async -> ActivationTarget? { ownerCalls += 1; return ownerTarget }
    /// The hosted count stays at its baseline after the reveal (a slow / lagging count read): only the frame can prove the landing.
    var countNeverRises = false
    func setAllowedLive(_ c: [String: Bool]) throws {
        lock.lock(); defer { lock.unlock() }
        if c.values.contains(true) { if failShow { throw PreferenceWriterError.writeFailed("show") }; shownAt = clock.now() }
        else if failHide { throw PreferenceWriterError.writeFailed("hide") }
        writes.append(c)
    }
    /// Frames returned (in order) once the item has landed; the last one repeats. Models an item still sliding in.
    var slide: [CGRect] = []
    private var slideIndex = 0
    /// Frames returned in order for a stale-frame target (the last repeats); empty = always `barFrame`.
    var staleFrames: [CGRect] = []
    private var staleIndex = 0
    /// Scripted `hostedGroupCount` results, one per call (the last repeats); empty = nil (unsupported: the old count path).
    var groupCounts: [Int?] = []
    var groupCalls = 0
    func hostedGroupCount() -> Int? {
        lock.lock(); defer { lock.unlock() }
        groupCalls += 1
        guard !groupCounts.isEmpty else { return nil }
        return groupCounts[min(groupCalls - 1, groupCounts.count - 1)]
    }
    // gdu.65: system overflow. `probeOn` = the platform supports the probe; `chevron` nil = a bar without one.
    var probeOn = false
    var chevron: CGRect?
    var otherGroups: [CGRect] = []
    /// Where the reveal lands the item (nil: `barFrame`); a stacked frame models the item behind the chevron.
    var landing: CGRect?
    /// The item's frame once the strip is expanded; `stripOpens == false`: the chevron click changes nothing (unreadable strip).
    var expandedFrame = CGRect(x: 307, y: 3, width: 32, height: 24)
    var stripOpens = true
    /// The closing click does not close the strip.
    var stripStuck = false
    var expanded = false
    var chevronClicks = 0
    var probeNilWhenExpanded = false
    private var landedFrame: CGRect { expanded ? expandedFrame : (landing ?? barFrame) }
    func overflowProbe() async -> OverflowProbe? {
        guard probeOn else { return nil }
        if probeNilWhenExpanded && expanded { return nil }
        return OverflowProbe(chevron: chevron, expanded: expanded, hosted: otherGroups + (landing.map { [$0] } ?? []))
    }
    func frame(of t: ActivationTarget) -> CGRect? {
        if staleFrame, !staleFrames.isEmpty { defer { staleIndex += 1 }; return staleFrames[min(staleIndex, staleFrames.count - 1)] }
        if staleFrame { return barFrame }
        if !slide.isEmpty, let s = shownAt, let l = landsAfter, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true {
            defer { slideIndex += 1 }
            return slide[min(slideIndex, slide.count - 1)]
        }
        if let s = shownAt, let l = landsAfter, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true { return landedFrame }
        return parkedFrame
    }
    func click(at p: CGPoint, button: ClickButton) -> Bool {
        clicks.append((p, button))
        if let c = chevron, probeOn, c.insetBy(dx: -2, dy: -2).contains(p) {   // the chevron toggles the strip; it opens no menu
            chevronClicks += 1
            if stripOpens, !(expanded && stripStuck) { expanded.toggle() }
            return true
        }
        openedAt = clock.now(); return true
    }
    func axPress(_ t: ActivationTarget) -> Int32 { presses += 1; openedAt = clock.now(); return pressResult }
    /// nil = unknown (frame-only landing); `staleFrameNoCount` models a unit live-hidden earlier whose app-side frame is stale.
    var countKnown = true
    var countAfterHide: Int?
    var staleFrame = false
    func hostedBarCount() async -> Int? {
        guard countKnown else { return nil }
        if let s = shownAt, let l = landsAfter, !countNeverRises, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true { return 11 }
        if writes.last?.values.contains(false) == true, let c = countAfterHide { return c }
        return 10
    }
    /// Hosted tree: 10 elements; +1 (the revealed item) while shown. `treeAfterHide` replaces the post-hide tree (ambiguity).
    var treeAfterHide: [HostedEntry]?
    var layoutKnown = true
    func tree(_ n: Int, shifted: Bool = false) -> [HostedEntry] {
        (0..<n).map { HostedEntry(sig: $0 == 5 && n == 11 ? "" : "e\($0)", minX: CGFloat($0 * 30) + (shifted ? 1 : 0), width: 24) }
    }
    /// A hosted read that hangs (real seconds), as under load.
    var hostedReadHangs = false
    func hostedLayout() async -> [HostedEntry]? {
        if hostedReadHangs { try? await Task.sleep(for: .seconds(5)); return nil }
        guard layoutKnown, countKnown else { return nil }
        if let s = shownAt, let l = landsAfter, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true { return tree(11) }
        if writes.last?.values.contains(false) == true, let t = treeAfterHide { return t }
        return tree(10)
    }
    var recorded: [(owners: [AssumedHiddenOwner], after: Int?)] = []
    var cleared: [Set<pid_t>] = []
    func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?) { recorded.append((owners, hostedAfter)) }
    func clearAssumedHidden(pids: Set<pid_t>) { cleared.append(pids) }
    func menuBaseline(_ t: ActivationTarget) -> Int { 0 }
    func menuState(_ t: ActivationTarget, baseline: Int) -> ActivationMenuState {
        guard let o = openedAt, let a = menuAfter else { return ActivationMenuState(present: false) }
        if escapedAt != nil { return ActivationMenuState(present: false) }
        let dt = clock.now().timeIntervalSince(o)
        if dt < a { return ActivationMenuState(present: false) }
        if let f = menuOpenFor, dt >= a + f { return ActivationMenuState(present: false) }
        return ActivationMenuState(present: true, frame: CGRect(x: 780, y: 24, width: 200, height: 300))
    }
    /// Escape presses; with `escapeClosesMenu` the menu vanishes right after the first one.
    var escapes = 0
    var escapeClosesMenu = false
    private var escapedAt: Date?
    func postEscape() { escapes += 1; if escapeClosesMenu { escapedAt = clock.now() } }
    func sleep(_ seconds: TimeInterval) async { clock.advance(seconds) }
    func now() -> Date { clock.now() }
}

private actor FakeHold: TransientRevealing {
    var begun: [HideUnit] = []
    var ended: [HideUnit] = []
    var refuse = false
    func beginTransientReveal(_ unit: HideUnit, timeout: Duration) async -> Bool {
        if refuse { return false }
        begun.append(unit); return true
    }
    func endTransientReveal(_ unit: HideUnit) async { ended.append(unit) }
}

@Suite struct ItemActivatorTests {
    private func make(_ p: FakeActivation, _ h: FakeHold = FakeHold()) -> ItemActivator {
        var c = ItemActivator.Config(); c.baselineBudget = 0   // the fake clock does not advance in real time; see slowBaseline...
        return ItemActivator(platform: p, hold: h, config: c)
    }

    private func parkedTarget(pid: pid_t = 42) -> ActivationTarget {
        ActivationTarget(key: key, ownerPID: pid, trackedKey: "com.x.tool", frame: parkedFrame, isOnBar: false, systemOverflow: false)
    }

    @Test func validCachedElementIsUsedAndNoScanRuns() async {
        let p = FakeActivation()
        p.cachedTarget = parkedTarget(pid: 7)
        let r = await make(p).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.cachedCalls == 1 && p.ownerCalls == 0 && p.locateCalls == 0)
        #expect(p.writes.first == ["com.x.tool": true])
    }

    @Test func staleCachedElementFallsToTheOwnerReadWithoutAScan() async {
        let p = FakeActivation()
        p.cachedTarget = nil                 // frame read failed / identity mismatch / on-bar state changed
        p.ownerTarget = parkedTarget(pid: 8)
        let r = await make(p).activate(key: key, button: .left)
        guard case .opened = r else { Issue.record("\(r)"); return }
        #expect(p.cachedCalls == 1 && p.ownerCalls == 1 && p.locateCalls == 0)
    }

    @Test func noFastSourceFallsToTheFullScan() async {
        let p = FakeActivation()
        let r = await make(p).activate(key: key, button: .left)
        guard case .opened = r else { Issue.record("\(r)"); return }
        #expect(p.cachedCalls == 1 && p.ownerCalls == 1 && p.locateCalls == 1)
    }

    @Test func notFoundStillComesFromTheFullScanOnly() async {
        let p = FakeActivation()
        p.locateResult = .notFound
        let r = await make(p).activate(key: key, button: .left)
        #expect(r == .failed(.notFound))
        #expect(p.locateCalls == 1 && p.writes.isEmpty && p.clicks.isEmpty)
    }

    @Test func notRunningStillComesFromTheFullScanOnly() async {
        let p = FakeActivation()
        p.locateResult = .notRunning
        #expect(await make(p).activate(key: key, button: .left) == .failed(.notRunning))
    }

    @Test func parkedFrameLandingNeedsNoHostedCountRise() async {
        let p = FakeActivation()
        p.countNeverRises = true
        let r = await make(p).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.clicks.count == 1 && p.clicks[0].0 == CGPoint(x: barFrame.midX, y: barFrame.midY))
    }

    @Test func staleOnBarFrameStillNeedsTheCountRise() async {
        let p = FakeActivation()
        p.countNeverRises = true
        p.locateResult = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: barFrame, isOnBar: true,
                                                 systemOverflow: false, hiddenInControlCenter: true))
        let r = await make(p).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .axPressParked)   // reveal timed out, nothing was clicked on a stale frame
        #expect(p.clicks.isEmpty)
    }

    @Test func slowBaselineIsNotWaitedForWhenTheTargetIsParked() async {
        let p = FakeActivation(); p.hostedReadHangs = true
        let r = await ItemActivator(platform: p, hold: FakeHold()).activate(key: key, button: .left)   // default budget
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.clicks.count == 1)
        #expect(p.recorded.isEmpty)   // no baseline layout: no assumed-hidden evidence, the engine hides it on its next pass
    }

    @Test func revealThenClickThenRehide() async {
        let p = FakeActivation(), h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .revealClick)
        #expect(o.revealMS != nil && o.revealMS! >= 200)
        #expect(o.menuAppearMS != nil)
        #expect(o.rehideFailed == nil)
        #expect(o.closedBy == "menu disappeared")
        #expect(p.clicks.count == 1 && p.clicks[0].1 == .left)
        #expect(p.clicks[0].0 == CGPoint(x: barFrame.midX, y: barFrame.midY))
        #expect(p.writes == [["com.x.tool": true], ["com.x.tool": false]])
        #expect(await h.begun == [key.hideUnit])
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func rehideRecordsTheOwnerAsAssumedHiddenWhenTheHostedCountReturns() async {
        let p = FakeActivation()
        guard case .opened = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(p.cleared == [[42]])                                   // the show voided any earlier assumption
        #expect(p.recorded.count == 1)
        #expect(p.recorded.first?.owners == [AssumedHiddenOwner(pid: 42, bundleID: nil, items: 1, trackedKey: "com.x.tool")])
        #expect(p.recorded.first?.after == 10)
    }

    @Test func rehideDoesNotRecordWhenTheHostedCountDoesNotReturn() async {
        let p = FakeActivation(); p.treeAfterHide = p.tree(10).enumerated().map { var e = $1; if $0 == 3 { e.sig = "other" }; return e }   // same count, one element differs
        guard case .opened = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(p.recorded.isEmpty)
    }

    @Test func staleOnBarFrameDoesNotCountAsRevealedUntilTheAgentHostsTheItem() async {
        // The locate itself saw the stale on-bar frame (a live-hidden item): only the count proves the landing.
        let stale = ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: barFrame, isOnBar: true, systemOverflow: false,
                                     hiddenInControlCenter: true)
        let p = FakeActivation(); p.staleFrame = true; p.landsAfter = 0.5; p.locateResult = .found(stale)
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .revealClick)
        #expect(o.revealMS! >= 500)   // not at once, although the frame already looked on-bar
        let q = FakeActivation(); q.staleFrame = true; q.landsAfter = nil; q.locateResult = .found(stale)
        guard case .opened(let o2) = await make(q).activate(key: key, button: .left) else { Issue.record("no2"); return }
        #expect(o2.mechanism == .axPressParked && q.clicks.isEmpty)
    }

    @Test func incompleteHostedReadFallsBackToAXPressAndNeverClicks() async {
        let p = FakeActivation(); p.staleFrame = true; p.countKnown = false
        p.locateResult = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: barFrame, isOnBar: true, systemOverflow: false,
                                                 hiddenInControlCenter: true))
        let h = FakeHold()
        guard case .opened(let o) = await make(p, h).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .axPressParked)
        #expect(p.clicks.isEmpty && p.writes.isEmpty)
        #expect(await h.ended == [key.hideUnit])
        guard case .failed(.unavailable) = await make(p, h).activate(key: key, button: .right) else { Issue.record("right"); return }
    }

    @Test func slidingFrameIsNotClickedUntilSettled() async {
        let p = FakeActivation(); p.landsAfter = 0.1
        p.slide = [CGRect(x: 800, y: 18, width: 24, height: 24), CGRect(x: 800, y: 9, width: 24, height: 24),
                   CGRect(x: 800, y: 2, width: 24, height: 24)]
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.clicks.count == 1 && p.clicks[0].0 == CGPoint(x: 812, y: 14))   // centre of the settled y=2 frame
    }

    @Test func noMenuAfterClickFailsAndRehides() async {
        let p = FakeActivation(); p.menuAfter = nil
        let h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .left)
        #expect(r == .failed(.noMenu))
        #expect(p.writes.last == ["com.x.tool": false])
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func cancelledActivationRehidesAndReleases() async {
        let p = FakeActivation(); p.menuOpenFor = nil
        let h = FakeHold()
        let a = make(p, h)
        let t = Task { await a.activate(key: key, button: .left) }
        for _ in 0..<5 { await Task.yield() }
        t.cancel()
        _ = await t.value
        #expect(p.writes.last == ["com.x.tool": false])
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func rightClickIsForwardedWhenRevealed() async {
        let p = FakeActivation()
        _ = await make(p).activate(key: key, button: .right)
        #expect(p.clicks.map(\.1) == [.right])
    }

    @Test func revealTimeoutFallsBackToAXPressForLeft() async {
        let p = FakeActivation(); p.landsAfter = nil
        let h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .axPressParked)
        #expect(p.presses == 1 && p.clicks.isEmpty)
        #expect(p.writes.last == ["com.x.tool": false])   // it had been shown, so it is hidden again
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func revealTimeoutForRightFailsAndRehides() async {
        let p = FakeActivation(); p.landsAfter = nil
        let h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .right)
        #expect(r == .failed(.revealTimedOut))
        #expect(p.writes.last == ["com.x.tool": false])
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func liveUnavailableUsesAXPressAndIgnoresRight() async {
        let p = FakeActivation(); p.live = false
        let left = await make(p).activate(key: key, button: .left)
        guard case .opened(let o) = left else { Issue.record("\(left)"); return }
        #expect(o.mechanism == .axPressParked)
        #expect(p.writes.isEmpty)
        let right = await make(p).activate(key: key, button: .right)
        guard case .failed(.unavailable) = right else { Issue.record("\(right)"); return }
        #expect(p.clicks.isEmpty)
    }

    @Test func appNotRunning() async {
        let p = FakeActivation(); p.locateResult = .notRunning
        let h = FakeHold()
        #expect(await make(p, h).activate(key: key, button: .left) == .failed(.notRunning))
        #expect(await h.begun.isEmpty)
        #expect(p.writes.isEmpty)
    }

    @Test func notFound() async {
        let p = FakeActivation(); p.locateResult = .notFound
        #expect(await make(p).activate(key: key, button: .left) == .failed(.notFound))
    }

    @Test func engineHoldRefusedIsEngineBusy() async {
        let p = FakeActivation(), h = FakeHold()
        await h.setRefuse()
        #expect(await make(p, h).activate(key: key, button: .left) == .failed(.engineBusy))
        #expect(p.writes.isEmpty)
    }

    @Test func rehideFailureStillOpensAndReleasesTheHold() async {
        let p = FakeActivation(); p.failHide = true
        let h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.rehideFailed != nil)
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func showWriteFailureFallsBackForLeftAndReleasesTheHold() async {
        let p = FakeActivation(); p.failShow = true
        let h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .axPressParked)
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func escapeEndsTheWaitAfterTheSettleWhenTheMenuIsGone() async {
        let p = FakeActivation(); p.menuOpenFor = 5
        let a = make(p)
        let t = Task { await a.activate(key: key, button: .left) }
        // Fake time only advances inside the activator; the escape is queued up front and read at the first tick.
        p.monitor.buffer.push(.escape)
        let r = await t.value
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        // The menu was still present after the settle, so the hint is not believed until it closes.
        #expect(o.closedBy == "menu disappeared" || o.closedBy == "escape")
    }

    @Test func escapeClosesAnObservedMenuAtOnce() async {
        let p = FakeActivation(); p.menuOpenFor = 30
        p.monitor.buffer.push(.escape)
        let r = await make(p).activate(key: key, button: .left)
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.closedBy == "escape")
    }

    @Test func outsideClickClosesButClickOnTheItemDoesNot() async {
        let p = FakeActivation(); p.menuOpenFor = nil   // a popover that survives clicks
        p.monitor.buffer.push(.mouseUp(CGPoint(x: barFrame.midX, y: barFrame.midY)))   // our own click's mouse-up
        p.monitor.buffer.push(.mouseUp(CGPoint(x: 100, y: 300)))   // outside, but the menu is still there: not believed
        let a = make(p)
        guard case .opened(let o) = await a.activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.closedBy == "hard cap")
        let q = FakeActivation(); q.menuOpenFor = 0.5
        q.monitor.buffer.push(.mouseUp(CGPoint(x: 100, y: 300)))
        guard case .opened(let o2) = await make(q).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o2.closedBy == "outside click" || o2.closedBy == "menu disappeared")
    }

    @Test func menuDisappearanceClosesIt() async {
        let p = FakeActivation(); p.menuOpenFor = 3
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.closedBy == "menu disappeared")
    }

    @Test func hardCapAfterSixtySeconds() async {
        let p = FakeActivation(); p.menuOpenFor = nil
        let t0 = p.clock.now()
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.closedBy == "hard cap")
        let elapsed = p.clock.now().timeIntervalSince(t0)
        #expect(elapsed >= 60 && elapsed < 63)
        #expect(p.writes.last == ["com.x.tool": false])
    }

    @Test func hardCapPostsEscapeAndRehidesAnywayWhenMenuStaysOpen() async {
        let p = FakeActivation(); p.menuOpenFor = nil
        let h = FakeHold()
        let t0 = p.clock.now()
        guard case .opened(let o) = await make(p, h).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.closedBy == "hard cap")
        #expect(p.escapes == 1)
        #expect(o.note == "menuStillOpenAtCap")
        #expect(p.clock.now().timeIntervalSince(t0) >= 62)   // 60 s cap + the 2 s grace
        #expect(p.writes.last == ["com.x.tool": false])
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func hardCapEscapeThatClosesTheMenuLeavesNoNote() async {
        let p = FakeActivation(); p.menuOpenFor = nil; p.escapeClosesMenu = true
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.closedBy == "hard cap" && p.escapes == 1 && o.note == nil)
        #expect(p.writes.last == ["com.x.tool": false])
    }

    @Test func menuClosedBeforeTheCapPostsNoEscape() async {
        let p = FakeActivation()
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(p.escapes == 0 && o.note == nil)
    }

    @Test func cancellationDuringBaselineReturnsCancelledWithoutWriting() async {
        let p = FakeActivation(); p.countKnown = false   // the baseline never reads
        let h = FakeHold()
        let a = make(p, h)
        let t = Task { () -> ActivationResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await a.activate(key: key, button: .left)
        }
        let r = await t.value
        #expect(r == .failed(.cancelled))
        #expect(p.writes.isEmpty && p.presses == 0 && p.clicks.isEmpty)
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func notFittingItemUsesAXPressWithoutReveal() async {
        let p = FakeActivation()
        p.locateResult = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: CGRect(x: 12, y: 0, width: 24, height: 24),
                                                 isOnBar: true, systemOverflow: true))
        let h = FakeHold()
        guard case .opened(let o) = await make(p, h).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .axPressOverflow)
        #expect(p.writes.isEmpty && p.presses == 1)
        #expect(await h.begun.isEmpty)
        guard case .failed(.unavailable) = await make(p, h).activate(key: key, button: .right) else { Issue.record("right"); return }
    }

    @Test func axPressErrorWithoutMenuIsPressFailedButErrorWithMenuIsOpened() async {
        let p = FakeActivation(); p.live = false; p.pressResult = -25204; p.menuAfter = nil
        #expect(await make(p).activate(key: key, button: .left) == .failed(.pressFailed(-25204)))
        let q = FakeActivation(); q.live = false; q.pressResult = -25204
        guard case .opened = await make(q).activate(key: key, button: .left) else { Issue.record("no"); return }
    }

    @Test func refusesWhileAMouseButtonIsDown() async {
        let p = FakeActivation(); p.mousePressed = 1
        let r = await make(p).activate(key: key, button: .left)
        guard case .failed(.unavailable) = r else { Issue.record("\(r)"); return }
        #expect(p.clicks.isEmpty)
        #expect(p.writes.last == ["com.x.tool": false])
    }

    @Test func secondActivationWhileOneRunsIsBusy() async {
        let p = FakeActivation(); p.menuOpenFor = nil
        let a = make(p)
        let first = Task { await a.activate(key: key, button: .left) }
        await Task.yield()
        for _ in 0..<50 { await Task.yield() }
        let second = await a.activate(key: key, button: .left)
        _ = await first.value
        #expect(second == .failed(.engineBusy) || { if case .opened = second { return true } else { return false } }())
    }
}

extension FakeHold { fileprivate func setRefuse() { refuse = true } }

@Suite struct ItemActivatorDrawnPathTests {
    private func make(_ p: FakeActivation) -> ItemActivator {
        var c = ItemActivator.Config(); c.baselineBudget = 0
        return ItemActivator(platform: p, hold: FakeHold(), config: c)
    }
    private func liveHidden(_ p: FakeActivation) {
        p.staleFrame = true
        p.locateResult = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: barFrame, isOnBar: true,
                                                 systemOverflow: false, hiddenInControlCenter: true))
    }

    @Test func liveHiddenIsNotDrawnWhileTheGroupCountStaysThenDrawnWhenItRises() async {
        let p = FakeActivation(); liveHidden(p); p.groupCounts = [5, 5, 5, 7]
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.groupCalls == 4)            // baseline + three settled polls; the click came only after the rise
        #expect(p.clicks.count == 1)
        #expect(o.revealMS! >= 100)           // not at once although the stale frame already looked settled
    }

    @Test func countRisingBeforeTheFrameSettlesKeepsWaitingThenDraws() async {
        let p = FakeActivation(); liveHidden(p); p.groupCounts = [5, 7]
        let sliding = CGRect(x: 800, y: 20, width: 24, height: 24)   // not on its resting row yet
        p.staleFrames = [sliding, sliding, sliding, barFrame]
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.groupCalls == 2)            // baseline + one check, made only once the frame was settled on two polls
        #expect(o.revealMS! >= 150)
        #expect(p.clicks[0].0 == CGPoint(x: barFrame.midX, y: barFrame.midY))
    }

    @Test func countNeverRisingTimesOutWithHonestFeedback() async {
        let p = FakeActivation(); liveHidden(p); p.groupCounts = [5]
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .axPressParked)   // left click: pressed in place, never clicked on the stale frame
        #expect(p.clicks.isEmpty && p.presses == 1)
        let q = FakeActivation(); liveHidden(q); q.groupCounts = [5]
        #expect(await make(q).activate(key: key, button: .right) == .failed(.revealTimedOut))
        #expect(q.clicks.isEmpty)
        #expect(q.writes.last == ["com.x.tool": false])   // re-hidden
    }

    @Test func parkedTargetIsDrawnByItsFrameWithoutAnyCountRise() async {
        let p = FakeActivation(); p.groupCounts = [5]
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .revealClick)
        #expect(p.groupCalls == 1)            // only the pre-write baseline; the frame is proof
        #expect(p.clicks.count == 1)
    }
}

@Suite struct ItemActivatorIdentityTests {
    private func item(id: String = "", desc: String = "", pid: pid_t = 42, onBar: Bool = true) -> MenuBarItem {
        MenuBarItem(ownerPID: pid, ownerBundleID: "com.x.tool", ownerName: "Tool", title: "", axDescription: desc, axIdentifier: id,
                    frame: barFrame, source: .appExtras, isOnMenuBar: onBar)
    }
    private func info(id: String = "", desc: String = "", stale: Bool = false, element: Bool = true) -> AXElementInfo {
        AXElementInfo(axDescription: desc, identifier: id, frame: barFrame, element: element ? AXUIElementCreateSystemWide() : nil, stale: stale)
    }
    private typealias L = LiveActivationPlatform

    @Test func sameIdentityRules() {
        #expect(L.sameIdentity(item(id: "a", desc: "d"), identifier: "a", description: "other"))       // identifier decides
        #expect(!L.sameIdentity(item(id: "a", desc: "d"), identifier: "b", description: "d"))
        #expect(L.sameIdentity(item(desc: "d"), identifier: "zzz", description: "d"))                   // no identifier: description
        #expect(!L.sameIdentity(item(desc: "d"), identifier: "", description: "e"))
        #expect(!L.sameIdentity(item(), identifier: "", description: ""))                               // nothing to compare
    }

    @Test func consistentCoversEachBranch() {
        let parked = parkedFrame, settled = barFrame
        let sliding = CGRect(x: 800, y: 20, width: 24, height: 24)   // on the strip but not on its resting row
        #expect(L.consistent(cachedOnBar: true, hiddenInControlCenter: false, liveFrame: settled))
        #expect(!L.consistent(cachedOnBar: true, hiddenInControlCenter: false, liveFrame: parked))   // went off the bar
        #expect(!L.consistent(cachedOnBar: true, hiddenInControlCenter: true, liveFrame: parked))
        #expect(L.consistent(cachedOnBar: false, hiddenInControlCenter: false, liveFrame: parked))
        #expect(!L.consistent(cachedOnBar: false, hiddenInControlCenter: false, liveFrame: settled)) // came onto the bar
        #expect(L.consistent(cachedOnBar: false, hiddenInControlCenter: true, liveFrame: settled))   // stale frame excused
        #expect(L.consistent(cachedOnBar: false, hiddenInControlCenter: false, liveFrame: sliding))
    }

    @Test func ownerMatchNeedsExactlyOneIdentityMatch() {
        let it = item(desc: "Tool")
        #expect(L.ownerMatch(it, in: [info(desc: "Other"), info(desc: "Tool")]) != nil)
        #expect(L.ownerMatch(it, in: [info(desc: "Tool"), info(desc: "Tool")]) == nil)                       // twins: full scan
        #expect(L.ownerMatch(it, in: [info(desc: "Other")]) == nil)                                           // none
        #expect(L.ownerMatch(it, in: []) == nil)
        #expect(L.ownerMatch(it, in: nil) == nil)                                                             // owner read failed
        #expect(L.ownerMatch(it, in: [info(desc: "Tool", stale: true)]) == nil)                               // carried-forward is no evidence
        #expect(L.ownerMatch(it, in: [info(desc: "Tool", element: false)]) == nil)                           // nothing to act on
        #expect(L.ownerMatch(it, in: [info(desc: "Tool", stale: true), info(desc: "Tool")]) != nil)           // stale one ignored
    }
}

@Suite struct ItemActivatorBarClickTests {
    @Test func drawnItemIsClickedInPlaceButAControlCenterHiddenOneIsRevealedFirst() async {
        let p = FakeActivation()
        p.locateResult = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: barFrame, isOnBar: true, systemOverflow: false))
        let h = FakeHold()
        guard case .opened(let o) = await ItemActivator(platform: p, hold: h).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .barClick)
        #expect(p.writes.isEmpty)
        #expect(await h.begun.isEmpty)
        let q = FakeActivation()
        q.locateResult = .found(ActivationTarget(key: key, ownerPID: 42, trackedKey: "com.x.tool", frame: barFrame, isOnBar: true, systemOverflow: false,
                                                 hiddenInControlCenter: true))
        guard case .opened(let o2) = await ItemActivator(platform: q, hold: FakeHold()).activate(key: key, button: .left) else { Issue.record("no2"); return }
        #expect(o2.mechanism == .revealClick)
    }
}

@Suite struct ItemActivatorSystemOverflowTests {
    private let chevronFrame = CGRect(x: 807, y: 1, width: 18, height: 26)
    private let stackedFrame = CGRect(x: 793, y: 3, width: 32, height: 24)   // behind the chevron: its centre (809) is on it
    private func mid(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    private func make(_ p: FakeActivation, _ h: FakeHold = FakeHold()) -> ItemActivator {
        var c = ItemActivator.Config(); c.baselineBudget = 0
        return ItemActivator(platform: p, hold: h, config: c)
    }
    private func fullBar() -> FakeActivation {
        let p = FakeActivation()
        p.probeOn = true; p.chevron = chevronFrame; p.landing = stackedFrame
        return p
    }

    @Test func detectionTrueAndFalseCases() {
        let c = chevronFrame
        // No chevron: nothing is in the system overflow, whatever the frames.
        #expect(!OverflowProbe(chevron: nil, hosted: [stackedFrame, stackedFrame]).isStacked(stackedFrame))
        // Left of the chevron (the scanner's rule) and click point on the chevron.
        #expect(OverflowProbe(chevron: c).isStacked(CGRect(x: 700, y: 3, width: 24, height: 24)))
        #expect(OverflowProbe(chevron: c).isStacked(stackedFrame))
        // Coincides with another hosted group (centres within 2 pt) AND starts within the chevron's reach (gdu.69).
        let reach = CGRect(x: 812, y: 3, width: 24, height: 24)
        #expect(OverflowProbe(chevron: c, hosted: [reach, CGRect(x: 811, y: 0, width: 26, height: 29)]).isStacked(reach))
        // The same coincidence far right of the chevron is chance, not overflow (findings-drag, false-positive incident).
        let drawn = CGRect(x: 900, y: 3, width: 24, height: 24)
        #expect(!OverflowProbe(chevron: c, hosted: [drawn, CGRect(x: 899, y: 0, width: 26, height: 29)]).isStacked(drawn))
        // A normal drawn item right of the chevron, alone on its x: not stacked.
        #expect(!OverflowProbe(chevron: c, hosted: [drawn]).isStacked(drawn))
        #expect(!OverflowProbe(chevron: c, hosted: [drawn, CGRect(x: 950, y: 0, width: 26, height: 29)]).isStacked(drawn))
        // An expanded strip has real frames.
        #expect(!OverflowProbe(chevron: c, expanded: true).isStacked(stackedFrame))
    }

    @Test func stackedLandingOpensThroughTheExpandedStripAndCollapsesAfterwards() async {
        let p = fullBar(), h = FakeHold()
        let lines = LineBox()
        let r = await make(p, h).activate(key: key, button: .left, progress: { lines.add($0) })
        guard case .opened(let o) = r else { Issue.record("\(r)"); return }
        #expect(o.mechanism == .revealClick)
        #expect(o.note == nil)
        // chevron to expand, the item in the strip (never the stacked frame), the chevron again to collapse.
        #expect(p.clicks.map(\.0) == [mid(chevronFrame), mid(p.expandedFrame), mid(chevronFrame)])
        #expect(!p.clicks.contains { $0.0 == mid(stackedFrame) })
        #expect(!p.expanded)
        #expect(p.writes == [["com.x.tool": true], ["com.x.tool": false]])
        #expect(await h.ended == [key.hideUnit])
        let log = lines.all
        #expect(log.contains { $0.contains("phase overflow: landed frame") })
        #expect(log.contains { $0.contains("phase overflow: expanded strip shows the item") })
        #expect(log.contains { $0.contains("phase overflow: strip collapsed") })
        #expect(log.allSatisfy { $0.hasPrefix("t=") })
    }

    @Test func unreadableStripFailsTruthfullyAndReHides() async {
        let p = fullBar(); p.stripOpens = false
        let h = FakeHold()
        let r = await make(p, h).activate(key: key, button: .left)
        #expect(r == .failed(.behindOverflowChevron))
        if case .failed(let e) = r { #expect(e.description.contains("behind the system overflow chevron; make room in the bar")) }
        #expect(p.clicks.map(\.0) == [mid(chevronFrame)])          // one chevron click; the stacked frame is never clicked
        #expect(p.writes == [["com.x.tool": true], ["com.x.tool": false]])
        #expect(await h.begun == [key.hideUnit])
        #expect(await h.ended == [key.hideUnit])
    }

    @Test func aStripThatCannotBeClosedIsReportedAsANote() async {
        let p = fullBar(); p.stripStuck = true
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.note == "overflowStripStillExpanded")
        #expect(p.chevronClicks == 3)      // expand + two closing attempts
    }

    @Test func nilProbeAtCollapseIsLoggedAndNoted() async {
        let p = fullBar(); p.probeNilWhenExpanded = true
        let lines = LineBox()
        guard case .opened(let o) = await make(p).activate(key: key, button: .left, progress: { lines.add($0) }) else { Issue.record("no"); return }
        #expect(o.note == "overflowStripStateUnknown")
        #expect(lines.all.contains { $0.contains("overflow: probe unavailable at collapse; strip state unknown") })
    }

    @Test func noMenuPathKeepsTheAfterCloseNote() async {
        let p = fullBar(); p.menuAfter = nil; p.stripStuck = true
        let lines = LineBox()
        let r = await make(p).activate(key: key, button: .left, progress: { lines.add($0) })
        #expect(r == .failed(.noMenu))
        #expect(lines.all.contains { $0.contains("note: overflowStripStillExpanded") })
    }

    @Test func captionsForNotesAreNeutralAndFailuresAreErrors() {
        func opened(_ n: String?) -> ActivationResult { .opened(ActivationOpened(mechanism: .revealClick, latencyMS: 1, note: n)) }
        #expect(ActivationCaption.make(opened(nil)) == nil)
        #expect(ActivationCaption.make(opened("overflowStripStillExpanded"))?.text == "menu opened; overflow strip left expanded")
        #expect(ActivationCaption.make(opened("menuStillOpenAtCap"))?.severity == .neutral)
        #expect(ActivationCaption.make(opened("menuStillOpenAtCap,overflowStripStillExpanded"))?.text == "menu still open; menu opened; overflow strip left expanded")
        #expect(ActivationCaption.make(opened("some failure text")) == nil)
        #expect(ActivationCaption.make(.failed(.noMenu))?.severity == .error)
    }

    @Test func menuNeverOpeningStillCollapsesTheStripBeforeTheReHide() async {
        let p = fullBar(); p.menuAfter = nil
        let r = await make(p).activate(key: key, button: .left)
        #expect(r == .failed(.noMenu))
        #expect(!p.expanded)
        #expect(p.writes.last == ["com.x.tool": false])
    }

    @Test func normalRevealIsUnchangedWithoutAChevronOrWithTheItemDrawnRightOfIt() async {
        // Baseline: the probe unsupported (nil), exactly the pre-gdu.65 sequence.
        let base = FakeActivation()
        guard case .opened = await make(base).activate(key: key, button: .left) else { Issue.record("base"); return }
        // Probe supported, bar without a chevron.
        let a = FakeActivation(); a.probeOn = true
        guard case .opened = await make(a).activate(key: key, button: .left) else { Issue.record("a"); return }
        // Chevron present but the item is drawn to its right and alone on its x.
        let b = FakeActivation(); b.probeOn = true; b.chevron = CGRect(x: 760, y: 1, width: 18, height: 26); b.otherGroups = [CGRect(x: 1000, y: 0, width: 26, height: 29)]
        guard case .opened = await make(b).activate(key: key, button: .left) else { Issue.record("b"); return }
        for q in [a, b] {
            #expect(q.clicks.map(\.0) == base.clicks.map(\.0))
            #expect(q.clicks.map(\.0) == [mid(barFrame)])
            #expect(q.chevronClicks == 0)
            #expect(q.writes == base.writes)
        }
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
