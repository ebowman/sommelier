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
    func locate(_ k: ItemKey) async -> ActivationLocate { locateResult }
    func setAllowedLive(_ c: [String: Bool]) throws {
        lock.lock(); defer { lock.unlock() }
        if c.values.contains(true) { if failShow { throw PreferenceWriterError.writeFailed("show") }; shownAt = clock.now() }
        else if failHide { throw PreferenceWriterError.writeFailed("hide") }
        writes.append(c)
    }
    /// Frames returned (in order) once the item has landed; the last one repeats. Models an item still sliding in.
    var slide: [CGRect] = []
    private var slideIndex = 0
    func frame(of t: ActivationTarget) -> CGRect? {
        if staleFrame { return barFrame }
        if !slide.isEmpty, let s = shownAt, let l = landsAfter, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true {
            defer { slideIndex += 1 }
            return slide[min(slideIndex, slide.count - 1)]
        }
        if let s = shownAt, let l = landsAfter, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true { return barFrame }
        return parkedFrame
    }
    func click(at p: CGPoint, button: ClickButton) -> Bool { clicks.append((p, button)); openedAt = clock.now(); return true }
    func axPress(_ t: ActivationTarget) -> Int32 { presses += 1; openedAt = clock.now(); return pressResult }
    /// nil = unknown (frame-only landing); `staleFrameNoCount` models a unit live-hidden earlier whose app-side frame is stale.
    var countKnown = true
    var staleFrame = false
    func hostedBarCount() async -> Int? {
        guard countKnown else { return nil }
        if let s = shownAt, let l = landsAfter, clock.now().timeIntervalSince(s) >= l, writes.last?.values.contains(true) == true { return 11 }
        return 10
    }
    func menuBaseline(_ t: ActivationTarget) -> Int { 0 }
    func menuState(_ t: ActivationTarget, baseline: Int) -> ActivationMenuState {
        guard let o = openedAt, let a = menuAfter else { return ActivationMenuState(present: false) }
        let dt = clock.now().timeIntervalSince(o)
        if dt < a { return ActivationMenuState(present: false) }
        if let f = menuOpenFor, dt >= a + f { return ActivationMenuState(present: false) }
        return ActivationMenuState(present: true, frame: CGRect(x: 780, y: 24, width: 200, height: 300))
    }
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
        ItemActivator(platform: p, hold: h)
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

    @Test func staleOnBarFrameDoesNotCountAsRevealedUntilTheAgentHostsTheItem() async {
        let p = FakeActivation(); p.staleFrame = true; p.landsAfter = 0.5
        guard case .opened(let o) = await make(p).activate(key: key, button: .left) else { Issue.record("no"); return }
        #expect(o.mechanism == .revealClick)
        #expect(o.revealMS! >= 500)   // not at once, although the frame already looked on-bar
        let q = FakeActivation(); q.staleFrame = true; q.landsAfter = nil
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
