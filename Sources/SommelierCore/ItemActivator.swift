import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum ClickButton: Equatable, Sendable { case left, right }

public enum ActivationMechanism: String, Equatable, Sendable {
    /// Unit shown live, synthesized click on the item's real on-bar frame (the preferred path).
    case revealClick
    /// Item already on the bar: click only.
    case barClick
    /// `kAXPressAction` on the parked item (menu appears at an odd place: docs/findings-visibility.md experiment C).
    case axPressParked
    /// `kAXPressAction` on an item macOS moved into its own overflow (on the bar per the agent, not drawn).
    case axPressOverflow
}

public enum ActivationError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound
    case notRunning
    case revealTimedOut
    case pressFailed(Int32)
    case engineBusy
    case unavailable(String)
    /// The click or press was delivered but no menu/popover appeared within the timeout.
    case noMenu
    case cancelled
    /// Why a revealed item cannot be opened: macOS drew it behind its own overflow chevron and the expanded strip was not readable.
    public static let behindOverflowChevron = ActivationError.unavailable("behind the system overflow chevron; make room in the bar")
    public var description: String {
        switch self {
        case .notFound: return "item not found on the menu bar"
        case .notRunning: return "the app is not running"
        case .revealTimedOut: return "the item did not appear on the bar in time"
        case .pressFailed(let e): return "Accessibility press failed (AXError \(e))"
        case .engineBusy: return "another reveal is in progress"
        case .unavailable(let why): return why
        case .noMenu: return "no menu opened"
        case .cancelled: return "cancelled"
        }
    }
}

public struct ActivationOpened: Equatable, Sendable {
    public var mechanism: ActivationMechanism
    /// `activate()` entry to the click (or press) being posted.
    public var latencyMS: Int
    /// Entry to the item being on the bar (revealClick only).
    public var revealMS: Int?
    /// Click posted to a menu/popover being observed (nil: never observed through Accessibility).
    public var menuAppearMS: Int?
    public var menuFrame: CGRect?
    /// Set when the re-hide write failed; the engine's next pass hides the item.
    public var rehideFailed: String?
    public var closedBy: String
    /// Extra remark: `menuStillOpenAtCap` when the menu survived the 60 s cap, an Escape and the grace wait (re-hidden anyway).
    public var note: String?
    public init(mechanism: ActivationMechanism, latencyMS: Int, revealMS: Int? = nil, menuAppearMS: Int? = nil,
                menuFrame: CGRect? = nil, rehideFailed: String? = nil, closedBy: String = "", note: String? = nil) {
        self.note = note
        self.mechanism = mechanism; self.latencyMS = latencyMS; self.revealMS = revealMS; self.menuAppearMS = menuAppearMS
        self.menuFrame = menuFrame; self.rehideFailed = rehideFailed; self.closedBy = closedBy
    }
}

public enum ActivationResult: Equatable, Sendable {
    case opened(ActivationOpened)
    case failed(ActivationError)
}

public enum CloseEvent: Equatable, Sendable {
    /// A mouse button was released at this point (global top-left coordinates).
    case mouseUp(CGPoint)
    case escape
}

/// Delivers menu-close hints (a global NSEvent monitor in the app). `start`/`stop` bracket one activation.
public protocol CloseMonitoring: Sendable {
    func start()
    func stop()
    func drain() -> [CloseEvent]
}

/// Thread-safe event buffer for `CloseMonitoring` implementations.
public final class CloseEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CloseEvent] = []
    public init() {}
    public func push(_ e: CloseEvent) { lock.lock(); events.append(e); lock.unlock() }
    public func drain() -> [CloseEvent] { lock.lock(); defer { lock.unlock() }; let e = events; events = []; return e }
}

public struct ActivationTarget: @unchecked Sendable {
    public var key: ItemKey
    public var ownerPID: pid_t
    /// Control Center `trackedApplications` key; nil when the item cannot be hidden/revealed that way.
    public var trackedKey: String?
    public var frame: CGRect
    public var isOnBar: Bool
    public var systemOverflow: Bool
    /// Opaque AX handle for the app-side element.
    public var element: AXUIElement?
    /// Control Center says the app is hidden (`isAllowed == false`). The scanner can still report such an item as on
    /// the bar (live-hidden items keep a stale app-side frame), so this, not `isOnBar`, decides whether it is drawn.
    public var hiddenInControlCenter: Bool
    public var bundleID: String?
    /// The hide unit the reveal holds (gdu.75): the tracked entry (`HideUnitRule` uses the same id), the owner-key unit when none.
    public var hideUnit: HideUnit { trackedKey.map { HideUnit(id: $0) } ?? key.hideUnit }
    public init(key: ItemKey, ownerPID: pid_t, trackedKey: String?, frame: CGRect, isOnBar: Bool, systemOverflow: Bool,
                element: AXUIElement? = nil, hiddenInControlCenter: Bool = false, bundleID: String? = nil) {
        self.bundleID = bundleID
        self.hiddenInControlCenter = hiddenInControlCenter
        self.key = key; self.ownerPID = ownerPID; self.trackedKey = trackedKey; self.frame = frame; self.isOnBar = isOnBar
        self.systemOverflow = systemOverflow; self.element = element
    }
}

/// Result slot for the time-boxed baseline read.
final class BaselineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var count: Int?
    private var layout: [HostedEntry]?
    func set(_ c: Int?, _ l: [HostedEntry]?) { lock.withLock { count = c; layout = l; done = true } }
    var isDone: Bool { lock.withLock { done } }
    var value: (Int?, [HostedEntry]?) { lock.withLock { (count, layout) } }
}

public enum ActivationLocate: Sendable {
    case found(ActivationTarget)
    case notRunning
    case notFound
}

public struct ActivationMenuState: Equatable, Sendable {
    public var present: Bool
    public var frame: CGRect?
    public init(present: Bool, frame: CGRect? = nil) { self.present = present; self.frame = frame }
}

/// What `ItemActivator` needs from the machine (`LiveActivationPlatform`; tests inject a fake).
public protocol ActivationPlatform: Sendable {
    var liveHideShowAvailable: Bool { get }
    func pressedMouseButtons() -> Int
    /// Full scan: authoritative, slow (0.6-1.8 s). The only source of `.notFound` / `.notRunning`.
    func locate(_ key: ItemKey) async -> ActivationLocate
    /// Fast locate from the last full scan's cached AX element: one element read, identity re-checked (owner pid + identifier /
    /// description). nil = cannot vouch for it (no cache, stale, identity or on-bar state changed): try the next source.
    func locateCached(_ key: ItemKey) async -> ActivationTarget?
    /// Fast locate by re-reading only the owner's `AXExtrasMenuBar`. nil = no unique identity match: do the full scan.
    func locateByOwner(_ key: ItemKey) async -> ActivationTarget?
    func setAllowedLive(_ changes: [String: Bool]) throws
    /// Current app-side frame of the item (fast, single attribute read); nil when unreadable.
    func frame(of target: ActivationTarget) -> CGRect?
    func click(at point: CGPoint, button: ClickButton) -> Bool
    /// Returns the AXError raw value (0 = success).
    func axPress(_ target: ActivationTarget) -> Int32
    /// Number of items MenuBarAgent currently hosts on the bar strip (the authoritative "drawn" set); nil when the read was
    /// incomplete. A live-hidden item keeps its stale on-bar app-side frame (docs/findings-live-trigger.md), so the
    /// frame alone cannot say that a reveal has landed: the count rising above its pre-reveal value does.
    func hostedBarCount() async -> Int?
    /// Quick top-level group count of the agent's hosted tree (ms, no descent into the owners); nil when unsupported/unreadable.
    /// A reveal adds a group; a live-hidden item has none, whatever its stale app-side frame says.
    func hostedGroupCount() -> Int?
    /// The hosted tree right now (complete read only), left to right; nil when incomplete or unsupported (of7).
    func hostedLayout() async -> [HostedEntry]?
    /// The agent's overflow chevron and hosted frames (top-level read, milliseconds); nil when unsupported or unreadable (the
    /// activator then behaves as it did before gdu.65: a settled frame is clicked).
    func overflowProbe() async -> OverflowProbe?
    /// Of7: records the owner as assumed live-hidden (our own re-hide write, confirmed by a hosted-count drop) / forgets it.
    func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?)
    func clearAssumedHidden(pids: Set<pid_t>)
    func menuBaseline(_ target: ActivationTarget) -> Int
    func menuState(_ target: ActivationTarget, baseline: Int) -> ActivationMenuState
    /// Posts an Escape key press (closes a menu left open at the hard cap). Default: nothing.
    func postEscape()
    var closeMonitor: (any CloseMonitoring)? { get }
    func sleep(_ seconds: TimeInterval) async
    func now() -> Date
}

extension ActivationPlatform {
    public func locateCached(_ key: ItemKey) async -> ActivationTarget? { nil }
    public func locateByOwner(_ key: ItemKey) async -> ActivationTarget? { nil }
    public func hostedLayout() async -> [HostedEntry]? { nil }
    public func hostedGroupCount() -> Int? { nil }
    public func overflowProbe() async -> OverflowProbe? { nil }
    public func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?) {}
    public func clearAssumedHidden(pids: Set<pid_t>) {}
    public func postEscape() {}
}

/// The engine side of a transient reveal (`LayoutEngine` conforms).
public protocol TransientRevealing: Sendable {
    func beginTransientReveal(_ unit: HideUnit, timeout: Duration) async -> Bool
    func endTransientReveal(_ unit: HideUnit) async
}

extension LayoutEngine: TransientRevealing {}

/// Opens the real menu/popover of a hidden menu bar item (overflow-panel click-forwarding). See docs/architecture.md.
public actor ItemActivator {
    public struct Config: Sendable {
        public var revealTimeout: TimeInterval = 1.5
        public var revealPoll: TimeInterval = 0.05
        public var menuAppearTimeout: TimeInterval = 1.5
        public var tick: TimeInterval = 0.1
        public var menuPoll: TimeInterval = 0.25
        public var settle: TimeInterval = 0.3
        public var hardCap: TimeInterval = 60
        /// At the hard cap an Escape is posted; how long to wait for the menu to vanish before re-hiding anyway.
        public var capEscapeGrace: TimeInterval = 2
        /// A reveal needs a complete hosted read as baseline; this many tries before falling back to AXPress.
        public var baselineAttempts = 2
        /// A PARKED target lands on its own frame, so the pre-reveal hosted read only feeds the re-hide evidence. Under load it
        /// takes 0.5-7 s: wait at most this long (seconds) for it, then reveal without it (the engine hides the unit on its next
        /// pass as usual). 0 = always wait for it (the original behaviour).
        public var baselineBudget: TimeInterval = 0.3
        /// gdu.65: after the chevron click, how long to wait for the target to show a real (unstacked, settled) frame in the
        /// expanded strip; and how long to wait for the strip to close again after the closing click.
        public var overflowExpandTimeout: TimeInterval = 1.0
        public var overflowCollapseTimeout: TimeInterval = 1.0
        /// ejb.30: observe-only. `activate` clicks, reveals (a Control Center write) and presses: it does none of them and answers `unavailable`.
        public var observeGate = ObserveOnlyGate(fixed: false)
        public init() {}
    }

    private let platform: any ActivationPlatform
    private let hold: any TransientRevealing
    private let config: Config
    private let log: @Sendable (String) -> Void
    private var inFlight = false
    /// Of7: set while a unit is revealed: owner, complete hosted count before the reveal, items the reveal added.
    private var reveal: (pid: pid_t, bundleID: String?, before: Int, items: Int, itemsKnown: Bool, layout: [HostedEntry]?)?

    public init(platform: any ActivationPlatform, hold: any TransientRevealing, config: Config = Config(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.platform = platform; self.hold = hold; self.config = config; self.log = log
    }

    public typealias Progress = @Sendable (String) -> Void

    /// Opens the item's menu and returns after it closed and the unit was hidden again (or immediately on failure).
    /// `progress` receives a line at each milestone (reveal, click, menu, close, re-hide).
    public func activate(key: ItemKey, button: ClickButton, forceAXPress: Bool = false,
                         progress: Progress? = nil) async -> ActivationResult {
        if config.observeGate.isOn {
            log("observe-only: would activate \(key) (\(button))")
            return .failed(.unavailable(ObserveOnly.nothingChanged))
        }
        guard !inFlight else { return .failed(.engineBusy) }
        inFlight = true
        defer { inFlight = false }
        let t0 = platform.now()
        func ms(_ d: Date = Date()) -> Int { Int(platform.now().timeIntervalSince(t0) * 1000) }
        func say(_ s: String) { log("activate \(key): t=\(ms())ms \(s)"); progress?("t=\(ms())ms \(s)") }

        // Locate, cheapest first: the cached element (ms), the owner's own extras (tens of ms), the full scan (0.6-1.8 s).
        let target: ActivationTarget
        var how = "cached element"
        if let t = await platform.locateCached(key) { target = t }
        else if let t = await platform.locateByOwner(key) { target = t; how = "owner read" }
        else {
            how = "full scan"
            switch await platform.locate(key) {
            case .found(let t): target = t
            case .notRunning: return .failed(.notRunning)
            case .notFound: return .failed(.notFound)
            }
        }
        say("phase locate: \(how) done (pid \(target.ownerPID), onBar=\(target.isOnBar), overflow=\(target.systemOverflow), frame=\(target.frame))")

        // Items macOS overflowed: on the bar per the agent but not drawn; nothing to reveal.
        if target.systemOverflow {
            guard button == .left else { return .failed(.unavailable("a right click needs the item drawn on the bar")) }
            return await pressAndWait(target, mechanism: .axPressOverflow, t0: t0, revealMS: nil, revealed: false, say: say)
        }
        // Already drawn (e.g. revealed by the user): click it where it is, no reveal, no hold.
        if target.isOnBar, !target.hiddenInControlCenter, Self.isSettledOnBar(target.frame), !forceAXPress {
            return await clickAndWait(target, button: button, mechanism: .barClick, t0: t0, revealMS: nil, revealed: false, say: say)
        }

        // Parked. Reveal + click needs the live writer and a tracked entry; otherwise AXPress in place (left only).
        let canReveal = platform.liveHideShowAvailable && target.trackedKey != nil && !forceAXPress
        if !canReveal {
            guard button == .left else {
                return .failed(.unavailable(forceAXPress ? "a right click cannot be forwarded with AXPress"
                                                         : "a right click needs the live reveal, which is unavailable"))
            }
            return await pressAndWait(target, mechanism: .axPressParked, t0: t0, revealMS: nil, revealed: false, say: say)
        }
        guard let tracked = target.trackedKey else { return .failed(.unavailable("no Control Center entry")) }
        let unit = target.hideUnit
        guard await hold.beginTransientReveal(unit, timeout: .seconds(Int(config.hardCap) + 5)) else { return .failed(.engineBusy) }
        // The pre-reveal hosted count, read right before the show write (after the hold). Without a complete baseline a
        // landed reveal cannot be told from a stale on-bar frame: do not reveal, press in place instead.
        let baselineStart = platform.now()
        var hostedBefore: Int?
        var layoutBefore: [HostedEntry]?
        var baselineSkipped = false
        // A quick group count proves a reveal even for a live-hidden item whose app-side frame is stale.
        let groupBefore = platform.hostedGroupCount()
        if (!Self.isSettledOnBar(target.frame) || groupBefore != nil), config.baselineBudget > 0 {
            let box = BaselineBox()
            let platform = self.platform
            let read = Task {
                if let l = await platform.hostedLayout() { box.set(l.count, l) } else { box.set(await platform.hostedBarCount(), nil) }
            }
            while !box.isDone, platform.now().timeIntervalSince(baselineStart) < config.baselineBudget, !Task.isCancelled {
                await platform.sleep(0.01)
            }
            if box.isDone { (hostedBefore, layoutBefore) = box.value }
            else if !Task.isCancelled { read.cancel(); baselineSkipped = true; hostedBefore = 0 }
        }
        for _ in 0..<(hostedBefore == nil ? config.baselineAttempts : 0) {
            if let l = await platform.hostedLayout() { layoutBefore = l; hostedBefore = l.count }
            else { hostedBefore = await platform.hostedBarCount() }
            if hostedBefore != nil || Task.isCancelled { break }
        }
        if hostedBefore == nil, Task.isCancelled {   // cancelled during the baseline: nothing was written, just release
            await hold.endTransientReveal(unit)
            say("cancelled during the baseline read")
            return .failed(.cancelled)
        }
        guard let hostedBefore else {
            await hold.endTransientReveal(unit)
            say("hosted read incomplete (\(config.baselineAttempts) tries); not revealing, pressing in place")
            guard button == .left else { return .failed(.unavailable("the menu bar could not be read completely; a right click needs the reveal")) }
            return await pressAndWait(target, mechanism: .axPressParked, t0: t0, revealMS: nil, revealed: false, say: say)
        }
        if baselineSkipped { say("phase baseline: skipped after \(Int(config.baselineBudget * 1000)) ms (slow hosted read); revealing on the frame alone, no re-hide evidence") }
        else { say("phase baseline: hosted count \(hostedBefore) read in \(Int(platform.now().timeIntervalSince(baselineStart) * 1000)) ms") }
        platform.clearAssumedHidden(pids: [target.ownerPID])   // we are showing it: any assumed-hidden state is void
        reveal = (target.ownerPID, target.bundleID, hostedBefore, 1, false, layoutBefore)
        let shownWriteStart = platform.now()
        do { try platform.setAllowedLive([tracked: true]) }
        catch {
            await hold.endTransientReveal(unit)
            say("live show failed: \(error)")
            guard button == .left else { return .failed(.unavailable("live reveal failed: \(error)")) }
            return await pressAndWait(target, mechanism: .axPressParked, t0: t0, revealMS: nil, revealed: false, say: say)
        }
        let shownAt = platform.now()
        say("phase show-write: unit shown (write done) in \(Int(platform.now().timeIntervalSince(shownWriteStart) * 1000)) ms")

        // Wait for the item to be drawn AND settled: the agent hosts one more item than before, and the app-side frame is on
        // the strip (y 0...5) and identical (+-1 pt) on two consecutive polls (a frame still sliding in is not clicked).
        // A target whose pre-reveal frame was PARKED lands unambiguously when its single element's frame reaches the strip and
        // holds (one cheap AX read per poll). A frame that already looked on the bar was stale (live-hidden item): only the
        // hosted count rising proves the reveal there. (sommelier-d5c: the count read is slow and often incomplete.)
        let frameIsProof = !Self.isSettledOnBar(target.frame)
        var landed: CGRect?
        var previous: CGRect?
        var cancelled = false
        while true {
            if Task.isCancelled { cancelled = true; break }
            if let f = platform.frame(of: target), Self.isSettledOnBar(f) {
                if let p = previous, Self.sameFrame(p, f) {
                    if frameIsProof { landed = f; break }
                    if let gb = groupBefore {
                        if let g = platform.hostedGroupCount(), g > gb { landed = f; say("phase drawn: agent groups \(gb) -> \(g)"); break }
                        // else: not proven yet; keep polling (cheap) until the reveal timeout
                    } else
                    if let now = await platform.hostedBarCount(), now > hostedBefore {
                        landed = f; reveal?.items = now - hostedBefore; reveal?.itemsKnown = true; break
                    }
                } else { previous = f }
            } else { previous = nil }
            if platform.now().timeIntervalSince(shownAt) > config.revealTimeout { break }
            await platform.sleep(config.revealPoll)
        }
        if cancelled {
            _ = await rehide(tracked: tracked, unit: unit, say: say)
            return .failed(.cancelled)
        }
        guard let landedFrame = landed else {
            say("reveal timed out")
            guard button == .left else {
                let note = await rehide(tracked: tracked, unit: unit, say: say)
                _ = note
                return .failed(.revealTimedOut)
            }
            return await pressAndWait(target, mechanism: .axPressParked, t0: t0, revealMS: nil, revealed: true, say: say, tracked: tracked)
        }
        let revealMS = ms()
        say("phase drawn: item on the bar at \(landedFrame), \(Int(platform.now().timeIntervalSince(shownAt) * 1000)) ms after the show write")
        var moved = target
        moved.frame = landedFrame
        // gdu.65: on a full bar the item can land in macOS's own overflow, behind the chevron: reported on the bar, settled,
        // counted by the agent, but not drawn, and a click on its stacked frame hits the chevron. Never click such a frame.
        if let probe = await platform.overflowProbe(), probe.isStacked(landedFrame), let chevron = probe.chevron {
            say("phase overflow: landed frame \(landedFrame) is stacked behind the system overflow chevron at \(chevron)")
            return await openThroughSystemOverflow(moved, stacked: landedFrame, chevron: chevron, button: button, t0: t0, revealMS: revealMS,
                                                   say: say, tracked: tracked)
        }
        return await clickAndWait(moved, button: button, mechanism: .revealClick, t0: t0, revealMS: revealMS, revealed: true, say: say, tracked: tracked)
    }

    // MARK: system overflow (gdu.65)

    /// (a) Click the chevron, wait for the target's own frame to become real in the expanded strip, click it there, and close
    /// the strip after the menu closed. (b) If the strip never shows the item: collapse again and fail with the cause.
    private func openThroughSystemOverflow(_ t: ActivationTarget, stacked: CGRect, chevron: CGRect, button: ClickButton, t0: Date,
                                           revealMS: Int, say: (String) -> Void, tracked: String) async -> ActivationResult {
        let unit = t.hideUnit
        func fail(_ e: ActivationError) async -> ActivationResult {
            _ = await rehide(tracked: tracked, unit: unit, say: say)
            return .failed(e)
        }
        let strip = stripController()
        var real: CGRect?
        var previous: CGRect?
        let outcome = await strip.open(chevron: chevron, checkAlreadyExpanded: false, ready: { [platform] in
            if let f = platform.frame(of: t), Self.isSettledOnBar(f), abs(f.minX - stacked.minX) > 2,
               !chevron.insetBy(dx: -2, dy: -2).contains(CGPoint(x: f.midX, y: f.midY)) {
                if let p = previous, Self.sameFrame(p, f) { real = f; return true }
                previous = f
            } else { previous = nil }
            return false
        }, say: say)
        let session: StripController.Session?
        switch outcome {
        case .mouseBusy: return await fail(.unavailable("a mouse button is pressed; click refused"))
        case .clickFailed: return await fail(.unavailable("could not post the click event"))
        case .ready(let s): session = s
        case .timedOut(let s), .cancelled(let s): session = s
        }
        let clickedAt = session?.openedAt ?? platform.now()
        guard let real else {
            say("phase overflow: the expanded strip did not show the item within \(Int(config.overflowExpandTimeout * 1000)) ms")
            _ = await strip.close(session, say: say)
            return await fail(Task.isCancelled ? .cancelled : .behindOverflowChevron)
        }
        say("phase overflow: expanded strip shows the item at \(real), \(Int(platform.now().timeIntervalSince(clickedAt) * 1000)) ms after the chevron click")
        var moved = t
        moved.frame = real
        return await clickAndWait(moved, button: button, mechanism: .revealClick, t0: t0, revealMS: revealMS, revealed: true, say: say, tracked: tracked,
                                  afterClose: { await strip.close(session, say: say) })
    }

    /// The shared strip helper (9o9.12) wired to this activator's platform and timeouts.
    private func stripController() -> StripController {
        let p = platform
        return StripController(click: { p.click(at: $0, button: .left) }, probe: { await p.overflowProbe() },
                               pressedButtons: { p.pressedMouseButtons() }, sleep: { await p.sleep($0) }, now: { p.now() },
                               timing: .init(expandTimeout: config.overflowExpandTimeout, collapseTimeout: config.overflowCollapseTimeout,
                                             poll: config.revealPoll))
    }

    static func isOnBarStrip(_ f: CGRect) -> Bool { f.width > 1 && f.minY < 30 && f.minX > 10 }
    /// Resting position on the bar: the item's top edge is within 0...5 pt of the screen top (live items sit at y 1...4).
    static func isSettledOnBar(_ f: CGRect) -> Bool { isOnBarStrip(f) && f.minY >= 0 && f.minY <= 5 }
    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    // MARK: click / press

    private func clickAndWait(_ t: ActivationTarget, button: ClickButton, mechanism: ActivationMechanism, t0: Date, revealMS: Int?,
                              revealed: Bool, say: (String) -> Void, tracked: String? = nil,
                              afterClose: () async -> String? = { nil }) async -> ActivationResult {
        let unit = t.hideUnit
        if platform.pressedMouseButtons() != 0 {
            if let n = await afterClose() { say("note: \(n)") }
            if revealed, let tracked { _ = await rehide(tracked: tracked, unit: unit, say: say) }
            return .failed(.unavailable("a mouse button is pressed; click refused"))
        }
        let baseline = platform.menuBaseline(t)
        platform.closeMonitor?.start()
        let centre = CGPoint(x: t.frame.midX, y: t.frame.midY)
        let posted = platform.click(at: centre, button: button)
        let clickMS = Int(platform.now().timeIntervalSince(t0) * 1000)
        guard posted else {
            platform.closeMonitor?.stop()
            if let n = await afterClose() { say("note: \(n)") }
            if revealed, let tracked { _ = await rehide(tracked: tracked, unit: unit, say: say) }
            return .failed(.unavailable("could not post the click event"))
        }
        say("phase click: posted at \(Int(centre.x)),\(Int(centre.y)) (\(button))")
        return await finish(t, mechanism: mechanism, clickMS: clickMS, revealMS: revealMS, baseline: baseline, revealed: revealed,
                            tracked: tracked, say: say, pressError: 0, requireMenu: false, afterClose: afterClose)
    }

    private func pressAndWait(_ t: ActivationTarget, mechanism: ActivationMechanism, t0: Date, revealMS: Int?, revealed: Bool,
                              say: (String) -> Void, tracked: String? = nil) async -> ActivationResult {
        let unit = t.hideUnit
        let baseline = platform.menuBaseline(t)
        platform.closeMonitor?.start()
        let err = platform.axPress(t)
        let pressMS = Int(platform.now().timeIntervalSince(t0) * 1000)
        say("AXPress returned \(err)")
        _ = unit
        return await finish(t, mechanism: mechanism, clickMS: pressMS, revealMS: revealMS, baseline: baseline, revealed: revealed,
                            tracked: tracked, say: say, pressError: err, requireMenu: true)
    }

    // MARK: menu lifetime

    private func finish(_ t: ActivationTarget, mechanism: ActivationMechanism, clickMS: Int, revealMS: Int?, baseline: Int, revealed: Bool,
                        tracked: String?, say: (String) -> Void, pressError: Int32, requireMenu: Bool,
                        afterClose: () async -> String? = { nil }) async -> ActivationResult {
        let unit = t.hideUnit
        let postedAt = platform.now()
        func since(_ d: Date) -> TimeInterval { platform.now().timeIntervalSince(d) }
        // 1. Wait for the menu to appear (up to menuAppearTimeout).
        var menuAppear: Int?
        var menuFrame: CGRect?
        while true {
            let s = platform.menuState(t, baseline: baseline)
            if s.present { menuAppear = Int(since(postedAt) * 1000); menuFrame = s.frame; break }
            if since(postedAt) > config.menuAppearTimeout || Task.isCancelled { break }
            await platform.sleep(config.revealPoll)
        }
        if let m = menuAppear { say("phase menu-open: menu observed \(m) ms after the click at \(menuFrame.map { "\($0)" } ?? "?")") }
        else { say("no menu observed through Accessibility") }

        if menuAppear == nil {
            platform.closeMonitor?.stop()
            if let n = await afterClose() { say("note: \(n)") }
            if revealed, let tracked { _ = await rehide(tracked: tracked, unit: unit, say: say) }
            if Task.isCancelled { return .failed(.cancelled) }
            return .failed(requireMenu && pressError != 0 ? .pressFailed(pressError) : .noMenu)
        }

        // 2. Wait for it to close: outside mouse-up / Escape (then settle), or the menu disappearing; hard cap.
        let menuSeen = menuAppear != nil
        var closedBy = "hard cap"
        var lastMenuPoll = platform.now()
        let waitStart = platform.now()
        loop: while since(waitStart) < config.hardCap {
            if Task.isCancelled { closedBy = "cancelled"; break loop }
            await platform.sleep(config.tick)
            var hint: String?
            for e in platform.closeMonitor?.drain() ?? [] {
                switch e {
                case .escape: hint = "escape"
                case .mouseUp(let p): if !t.frame.insetBy(dx: -2, dy: -2).contains(p) { hint = "outside click" }
                }
            }
            if let hint {
                await platform.sleep(config.settle)
                // Escape closes a menu or popover. A mouse-up outside the item can also be a click INSIDE a popover, which
                // survives it: believe that hint only if the menu is gone (or was never observed).
                if hint == "escape" || !menuSeen || !platform.menuState(t, baseline: baseline).present { closedBy = hint; break loop }
                continue
            }
            if menuSeen, since(lastMenuPoll) >= config.menuPoll {
                lastMenuPoll = platform.now()
                if !platform.menuState(t, baseline: baseline).present {
                    await platform.sleep(config.settle)
                    closedBy = "menu disappeared"; break loop
                }
            }
        }
        platform.closeMonitor?.stop()
        var note: String?
        if closedBy == "hard cap" {
            // Re-hiding while the menu is still open strands it (seen live with Moom): Escape, then wait for it to vanish.
            say("hard cap reached; posting Escape before re-hide")
            platform.postEscape()
            let escAt = platform.now()
            var gone = false
            while since(escAt) < config.capEscapeGrace {
                await platform.sleep(config.revealPoll)
                if !platform.menuState(t, baseline: baseline).present { gone = true; break }
            }
            if !gone { note = "menuStillOpenAtCap"; say("menu still open after Escape; re-hiding anyway") }
        }
        say("menu closed (\(closedBy))")
        if let n = await afterClose() { note = [note, n].compactMap { $0 }.joined(separator: ",") }

        // 3. Hide again; never retry here.
        var rehideNote: String?
        if revealed, let tracked { rehideNote = await rehide(tracked: tracked, unit: unit, say: say) }
        return .opened(ActivationOpened(mechanism: mechanism, latencyMS: clickMS, revealMS: revealMS, menuAppearMS: menuAppear,
                                        menuFrame: menuFrame, rehideFailed: rehideNote, closedBy: closedBy, note: note))
    }

    /// Writes the re-hide and releases the hold either way. Returns the failure text, nil on success.
    private func rehide(tracked: String, unit: HideUnit, say: (String) -> Void) async -> String? {
        var note: String?
        var info = reveal
        reveal = nil
        // Reveals that landed on the frame alone did not count what came back; count it now (menu closed, not latency-bound).
        if let i = info, !i.itemsKnown, i.layout != nil, let now = await platform.hostedBarCount(), now > i.before {
            info?.items = now - i.before
        }
        do {
            try platform.setAllowedLive([tracked: false]); say("unit hidden again (write done)")
            // Of7: identifier-less items keep a stale on-bar frame after this live hide. If the hosted tree is again exactly
            // what it was before the reveal (same elements, same order), record the owner as assumed-hidden (still under the
            // hold) so the engine's next pass reads the unit as hidden instead of planning a hide that ends in a respawn.
            if let info, let layout = info.layout {
                let tw = platform.now()
                for at in [0.3, 0.8, 1.5, 2.5, 4.0, 6.0] {
                    let due = at - platform.now().timeIntervalSince(tw); if due > 0 { await platform.sleep(due) }
                    guard let after = await platform.hostedLayout() else { say("re-hide: probe @\(Int(at * 1000))ms incomplete"); continue }
                    if HostedEvidence.restored(before: layout, after: after) {
                        platform.recordAssumedHidden([AssumedHiddenOwner(pid: info.pid, bundleID: info.bundleID, items: max(1, info.items), trackedKey: tracked)], hostedAfter: after.count)
                        say("re-hide verified by hosted-element evidence (tree restored, \(after.count) elements); recorded as assumed-hidden")
                        break
                    }
                    say("re-hide: probe @\(Int(at * 1000))ms: not restored: \(HostedEvidence.restoredMismatch(before: layout, after: after) ?? "?")")
                }
            }
        }
        catch { note = "\(error)"; say("re-hide failed: \(error); the engine will hide it") }
        await hold.endTransientReveal(unit)
        return note
    }
}

// MARK: - Live platform

/// Real machine: full scan for locating, live Control Center writes, AX frame reads, CGEvent clicks.
public final class LiveActivationPlatform: ActivationPlatform, @unchecked Sendable {
    private let platform: LivePlatform
    private let drop: @Sendable ([ResolvedItem]) -> [ResolvedItem]
    public let closeMonitor: (any CloseMonitoring)?

    public init(platform: LivePlatform = LivePlatform(), closeMonitor: (any CloseMonitoring)? = nil,
                filter: @escaping @Sendable ([ResolvedItem]) -> [ResolvedItem] = { $0 }) {
        self.platform = platform; self.closeMonitor = closeMonitor; self.drop = filter
    }

    public var liveHideShowAvailable: Bool { platform.liveHideShowAvailable }
    public func pressedMouseButtons() -> Int { platform.pressedMouseButtons() }
    public func setAllowedLive(_ changes: [String: Bool]) throws { try platform.setAllowedLive(changes) }
    public func sleep(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }
    public func now() -> Date { Date() }
    public func postEscape() { if platform.observeOnly { return }; DragMover.postEscape() }

    public func locate(_ key: ItemKey) async -> ActivationLocate {
        let snap = await platform.scan()
        let resolved = drop(platform.resolve(snap))
        guard let r = resolved.first(where: { $0.key == key }) else {
            return Self.ownerRunning(key) ? .notFound : .notRunning
        }
        if NSRunningApplication(processIdentifier: r.item.ownerPID)?.isTerminated ?? true { return .notRunning }
        return .found(makeTarget(key: key, r.item, element: r.item.axElement, frame: r.item.frame, resolved: r))
    }

    private func makeTarget(key: ItemKey, _ item: MenuBarItem, element: AXUIElement?, frame: CGRect, resolved r: ResolvedItem) -> ActivationTarget {
        let tracked = platform.trackedKey(for: r)
        // Through CFPreferences when usable: the plist file lags a live (cfprefsd-notified) write by seconds.
        let allowed = tracked.flatMap { t in
            (platform.liveHideShowAvailable ? (try? ControlCenterTrackedAppsStore.allowedLive([t])) : (try? platform.readAllowed([t])))?[t]
        }
        return ActivationTarget(key: key, ownerPID: item.ownerPID, trackedKey: tracked,
                                frame: frame, isOnBar: item.isOnMenuBar, systemOverflow: item.systemOverflow,
                                element: element, hiddenInControlCenter: allowed == false, bundleID: item.ownerBundleID)
    }

    /// A cached scan older than this is not trusted for locating (`isOnBar` / `systemOverflow` come from it).
    static let cacheMaxAge: TimeInterval = 120

    /// The cached item for `key` from the newest full scan, when usable for a fast locate: fresh, owner alive, a real app extra
    /// with a non-empty identifier or description (the identity the re-check compares).
    private func cachedResolved(_ key: ItemKey) -> ResolvedItem? {
        guard let (snap, at) = platform.lastFullScan(), Date().timeIntervalSince(at) <= Self.cacheMaxAge else { return nil }
        guard let r = drop(platform.resolve(snap)).first(where: { $0.key == key }) else { return nil }
        let it = r.item
        guard it.source == .appExtras, !it.stale, !it.axIdentifier.isEmpty || !it.axDescription.isEmpty else { return nil }
        guard let app = NSRunningApplication(processIdentifier: it.ownerPID), !app.isTerminated else { return nil }
        return r
    }

    /// Does the item as read now (frame, identifier, description) still describe the cached one? Identifier decides when the
    /// cached item had one, else the description (titles are volatile readouts).
    static func sameIdentity(_ item: MenuBarItem, identifier: String, description: String) -> Bool {
        if !item.axIdentifier.isEmpty { return identifier == item.axIdentifier }
        if !item.axDescription.isEmpty { return description == item.axDescription }
        return false
    }

    /// The on-bar state of the cached item must still agree with the live frame; otherwise the cache is out of date.
    /// (A live-hidden item keeps a stale on-bar frame, so a Control Center "hidden" flag excuses an on-strip frame.)
    private func consistent(_ r: ResolvedItem, liveFrame f: CGRect, target t: ActivationTarget) -> Bool {
        Self.consistent(cachedOnBar: r.item.isOnMenuBar, hiddenInControlCenter: t.hiddenInControlCenter, liveFrame: f)
    }

    static func consistent(cachedOnBar: Bool, hiddenInControlCenter: Bool, liveFrame f: CGRect) -> Bool {
        if cachedOnBar && !ItemActivator.isOnBarStrip(f) { return false }
        if !cachedOnBar && !hiddenInControlCenter && ItemActivator.isSettledOnBar(f) { return false }
        return true
    }

    /// The single owner-read element carrying the cached item's identity; nil when the read failed (nil) or zero / several match.
    static func ownerMatch(_ item: MenuBarItem, in infos: [AXElementInfo]?) -> AXElementInfo? {
        guard let infos else { return nil }
        let hits = infos.filter { !$0.stale && sameIdentity(item, identifier: $0.identifier, description: $0.axDescription) }
        guard hits.count == 1, hits[0].element != nil else { return nil }
        return hits[0]
    }

    public func locateCached(_ key: ItemKey) async -> ActivationTarget? {
        guard let r = cachedResolved(key), let el = r.item.axElement,
              let live = Self.readIdentity(el), live.pid == r.item.ownerPID,
              Self.sameIdentity(r.item, identifier: live.identifier, description: live.description) else { return nil }
        let t = makeTarget(key: key, r.item, element: el, frame: live.frame, resolved: r)
        return consistent(r, liveFrame: live.frame, target: t) ? t : nil
    }

    public func locateByOwner(_ key: ItemKey) async -> ActivationTarget? {
        guard let r = cachedResolved(key) else { return nil }
        let item = r.item
        // Exactly one element may carry the identity; two same-fingerprint items need the full scan's ordinal logic.
        guard let hit = Self.ownerMatch(item, in: platform.readOwnerExtras(pid: item.ownerPID, bundleID: item.ownerBundleID, name: item.ownerName)),
              let el = hit.element else { return nil }
        let t = makeTarget(key: key, item, element: el, frame: hit.frame, resolved: r)
        return consistent(r, liveFrame: hit.frame, target: t) ? t : nil
    }

    /// One element's pid, identifier, description and frame (five attribute reads, a few ms); nil when any is unreadable.
    static func readIdentity(_ el: AXUIElement) -> (pid: pid_t, identifier: String, description: String, frame: CGRect)? {
        AXUIElementSetMessagingTimeout(el, 0.3)
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid > 0, let f = frame(el) else { return nil }
        func str(_ attr: String) -> String {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? (v as? String ?? "") : ""
        }
        return (pid, str(kAXIdentifierAttribute as String), str(kAXDescriptionAttribute as String), f)
    }

    static func ownerRunning(_ key: ItemKey) -> Bool {
        switch key {
        case .status(let owner, _): return !NSRunningApplication.runningApplications(withBundleIdentifier: owner).isEmpty
        case .heuristic(let b, _, _): return !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty
        case .module: return true
        }
    }

    public func hostedBarCount() async -> Int? { await platform.hostedBarCount() }
    public func hostedGroupCount() -> Int? { platform.hostedGroupCount() }
    public func hostedLayout() async -> [HostedEntry]? { await platform.hostedLayout() }
    public func overflowProbe() async -> OverflowProbe? { await platform.overflowProbe() }
    public func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?) { platform.recordAssumedHidden(owners, hostedAfter: hostedAfter) }
    public func clearAssumedHidden(pids: Set<pid_t>) { platform.clearAssumedHidden(pids: pids) }

    public func frame(of t: ActivationTarget) -> CGRect? {
        guard let el = t.element else { return nil }
        AXUIElementSetMessagingTimeout(el, 0.3)
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let pv = axValue(from: p), let sv = axValue(from: s) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pt), AXValueGetValue(sv, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    public func click(at point: CGPoint, button: ClickButton) -> Bool {
        if platform.observeOnly { AppLog.log(.activator, "observe-only: would click"); return false }
        return SyntheticClick.post(at: point, button: button)
    }

    public func axPress(_ t: ActivationTarget) -> Int32 {
        guard let el = t.element else { return AXError.invalidUIElement.rawValue }
        if platform.observeOnly { AppLog.log(.activator, "observe-only: would AXPress"); return AXError.cannotComplete.rawValue }
        AXUIElementSetMessagingTimeout(el, 2.0)
        return AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue
    }

    /// Menu-ish things currently attached to the item: AXMenu/AXPopover children with a real size, plus the app's AX windows.
    /// Counting the app's windows is deliberate: popovers are windows, so any NEW app window after the click counts as the
    /// menu (a side effect: an unrelated window the app opens meanwhile is also taken for one).
    /// A menu or popover is "present" when this count exceeds its value from before the click (some apps keep an empty,
    /// zero-sized AXMenu child around permanently).
    public func menuBaseline(_ t: ActivationTarget) -> Int { menuThings(t).count }

    public func menuState(_ t: ActivationTarget, baseline: Int) -> ActivationMenuState {
        let m = menuThings(t)
        return m.count > baseline ? ActivationMenuState(present: true, frame: m.frame) : ActivationMenuState(present: false)
    }

    private func menuThings(_ t: ActivationTarget) -> (count: Int, frame: CGRect?) {
        var count = 0
        var frame: CGRect?
        if let el = t.element {
            AXUIElementSetMessagingTimeout(el, 0.3)
            var ch: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ch) == .success, let kids = ch as? [AnyObject] {
                for k in kids {
                    guard let e = axElement(from: k) else { continue }
                    var role: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success,
                          let r = role as? String, r == (kAXMenuRole as String) || r == "AXPopover" else { continue }
                    let f = Self.frame(e)
                    if let f, f.width > 1, f.height > 1 { count += 1; frame = frame ?? f }
                }
            }
        }
        let app = AXUIElementCreateApplication(t.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var wins: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success, let list = wins as? [AnyObject] {
            count += list.count
            if frame == nil, let last = list.last.flatMap(axElement(from:)) { frame = Self.frame(last) }
        }
        return (count, frame)
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let pv = axValue(from: p), let sv = axValue(from: s) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pt), AXValueGetValue(sv, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}
