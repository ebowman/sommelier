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
    public var description: String {
        switch self {
        case .notFound: return "item not found on the menu bar"
        case .notRunning: return "the app is not running"
        case .revealTimedOut: return "the item did not appear on the bar in time"
        case .pressFailed(let e): return "Accessibility press failed (AXError \(e))"
        case .engineBusy: return "another reveal is in progress"
        case .unavailable(let why): return why
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
    public init(mechanism: ActivationMechanism, latencyMS: Int, revealMS: Int? = nil, menuAppearMS: Int? = nil,
                menuFrame: CGRect? = nil, rehideFailed: String? = nil, closedBy: String = "") {
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
    public init(key: ItemKey, ownerPID: pid_t, trackedKey: String?, frame: CGRect, isOnBar: Bool, systemOverflow: Bool,
                element: AXUIElement? = nil, hiddenInControlCenter: Bool = false) {
        self.hiddenInControlCenter = hiddenInControlCenter
        self.key = key; self.ownerPID = ownerPID; self.trackedKey = trackedKey; self.frame = frame; self.isOnBar = isOnBar
        self.systemOverflow = systemOverflow; self.element = element
    }
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
    func locate(_ key: ItemKey) async -> ActivationLocate
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
    func menuBaseline(_ target: ActivationTarget) -> Int
    func menuState(_ target: ActivationTarget, baseline: Int) -> ActivationMenuState
    var closeMonitor: (any CloseMonitoring)? { get }
    func sleep(_ seconds: TimeInterval) async
    func now() -> Date
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
        /// Without a hosted-count baseline, how long after the show write a stale on-bar frame is believed.
        public var unverifiedRevealWait: TimeInterval = 0.6
        public init() {}
    }

    private let platform: any ActivationPlatform
    private let hold: any TransientRevealing
    private let config: Config
    private let log: @Sendable (String) -> Void
    private var inFlight = false

    public init(platform: any ActivationPlatform, hold: any TransientRevealing, config: Config = Config(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.platform = platform; self.hold = hold; self.config = config; self.log = log
    }

    public typealias Progress = @Sendable (String) -> Void

    /// Opens the item's menu and returns after it closed and the unit was hidden again (or immediately on failure).
    /// `progress` receives a line at each milestone (reveal, click, menu, close, re-hide).
    public func activate(key: ItemKey, button: ClickButton, forceAXPress: Bool = false,
                         progress: Progress? = nil) async -> ActivationResult {
        guard !inFlight else { return .failed(.engineBusy) }
        inFlight = true
        defer { inFlight = false }
        let t0 = platform.now()
        func ms(_ d: Date = Date()) -> Int { Int(platform.now().timeIntervalSince(t0) * 1000) }
        func say(_ s: String) { log("activate \(key): \(s)"); progress?("t=\(ms())ms \(s)") }

        let target: ActivationTarget
        switch await platform.locate(key) {
        case .found(let t): target = t
        case .notRunning: return .failed(.notRunning)
        case .notFound: return .failed(.notFound)
        }
        say("located (pid \(target.ownerPID), onBar=\(target.isOnBar), overflow=\(target.systemOverflow), frame=\(target.frame))")

        // Items macOS overflowed: on the bar per the agent but not drawn; nothing to reveal.
        if target.systemOverflow {
            guard button == .left else { return .failed(.unavailable("a right click needs the item drawn on the bar")) }
            return await pressAndWait(target, mechanism: .axPressOverflow, t0: t0, revealMS: nil, revealed: false, say: say)
        }
        // Already drawn (e.g. revealed by the user): click it where it is, no reveal, no hold.
        if target.isOnBar, !target.hiddenInControlCenter, Self.isOnBarStrip(target.frame), !forceAXPress {
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
        let unit = key.hideUnit
        // The pre-reveal hosted count; nil when the read was incomplete (no retry: it sits on the latency path).
        let hostedBefore = await platform.hostedBarCount()
        guard await hold.beginTransientReveal(unit, timeout: .seconds(Int(config.hardCap) + 5)) else { return .failed(.engineBusy) }
        do { try platform.setAllowedLive([tracked: true]) }
        catch {
            await hold.endTransientReveal(unit)
            say("live show failed: \(error)")
            guard button == .left else { return .failed(.unavailable("live reveal failed: \(error)")) }
            return await pressAndWait(target, mechanism: .axPressParked, t0: t0, revealMS: nil, revealed: false, say: say)
        }
        let shownAt = platform.now()
        say("unit shown (write done)")

        // Wait for the item's own frame to land on the bar strip.
        var landed: CGRect?
        while true {
            if let f = platform.frame(of: target), Self.isOnBarStrip(f) {
                // Frame on the strip is necessary, not sufficient: the agent must also host one more item than before.
                if let before = hostedBefore {
                    if let now = await platform.hostedBarCount(), now > before { landed = f; break }
                } else if !Self.isOnBarStrip(target.frame) || platform.now().timeIntervalSince(shownAt) >= config.unverifiedRevealWait {
                    // No baseline: a frame that moved from the parked spot is proof enough; a frame that looked on-bar
                    // already (stale) is believed only after the agent had time to draw the item.
                    landed = f; break
                }
            }
            if platform.now().timeIntervalSince(shownAt) > config.revealTimeout { break }
            await platform.sleep(config.revealPoll)
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
        say("item on the bar at \(landedFrame)")
        var moved = target
        moved.frame = landedFrame
        return await clickAndWait(moved, button: button, mechanism: .revealClick, t0: t0, revealMS: revealMS, revealed: true, say: say, tracked: tracked)
    }

    static func isOnBarStrip(_ f: CGRect) -> Bool { f.width > 1 && f.minY < 30 && f.minX > 10 }

    // MARK: click / press

    private func clickAndWait(_ t: ActivationTarget, button: ClickButton, mechanism: ActivationMechanism, t0: Date, revealMS: Int?,
                              revealed: Bool, say: (String) -> Void, tracked: String? = nil) async -> ActivationResult {
        let unit = t.key.hideUnit
        if platform.pressedMouseButtons() != 0 {
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
            if revealed, let tracked { _ = await rehide(tracked: tracked, unit: unit, say: say) }
            return .failed(.unavailable("could not post the click event"))
        }
        say("click posted at \(Int(centre.x)),\(Int(centre.y)) (\(button))")
        return await finish(t, mechanism: mechanism, clickMS: clickMS, revealMS: revealMS, baseline: baseline, revealed: revealed,
                            tracked: tracked, say: say, pressError: 0, requireMenu: false)
    }

    private func pressAndWait(_ t: ActivationTarget, mechanism: ActivationMechanism, t0: Date, revealMS: Int?, revealed: Bool,
                              say: (String) -> Void, tracked: String? = nil) async -> ActivationResult {
        let unit = t.key.hideUnit
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
                        tracked: String?, say: (String) -> Void, pressError: Int32, requireMenu: Bool) async -> ActivationResult {
        let unit = t.key.hideUnit
        let postedAt = platform.now()
        func since(_ d: Date) -> TimeInterval { platform.now().timeIntervalSince(d) }
        // 1. Wait for the menu to appear (up to menuAppearTimeout).
        var menuAppear: Int?
        var menuFrame: CGRect?
        while true {
            let s = platform.menuState(t, baseline: baseline)
            if s.present { menuAppear = Int(since(postedAt) * 1000); menuFrame = s.frame; break }
            if since(postedAt) > config.menuAppearTimeout { break }
            await platform.sleep(config.revealPoll)
        }
        if let m = menuAppear { say("menu observed \(m) ms after the click at \(menuFrame.map { "\($0)" } ?? "?")") }
        else { say("no menu observed through Accessibility") }

        if requireMenu, menuAppear == nil, pressError != 0 {
            platform.closeMonitor?.stop()
            if revealed, let tracked { _ = await rehide(tracked: tracked, unit: unit, say: say) }
            return .failed(.pressFailed(pressError))
        }

        // 2. Wait for it to close: outside mouse-up / Escape (then settle), or the menu disappearing; hard cap.
        let menuSeen = menuAppear != nil
        var closedBy = "hard cap"
        var lastMenuPoll = platform.now()
        let waitStart = platform.now()
        loop: while since(waitStart) < config.hardCap {
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
        say("menu closed (\(closedBy))")

        // 3. Hide again; never retry here.
        var note: String?
        if revealed, let tracked { note = await rehide(tracked: tracked, unit: unit, say: say) }
        return .opened(ActivationOpened(mechanism: mechanism, latencyMS: clickMS, revealMS: revealMS, menuAppearMS: menuAppear,
                                        menuFrame: menuFrame, rehideFailed: note, closedBy: closedBy))
    }

    /// Writes the re-hide and releases the hold either way. Returns the failure text, nil on success.
    private func rehide(tracked: String, unit: HideUnit, say: (String) -> Void) async -> String? {
        var note: String?
        do { try platform.setAllowedLive([tracked: false]); say("unit hidden again (write done)") }
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

    public func locate(_ key: ItemKey) async -> ActivationLocate {
        let snap = await platform.scan()
        let resolved = drop(platform.resolve(snap))
        guard let r = resolved.first(where: { $0.key == key }) else {
            return Self.ownerRunning(key) ? .notFound : .notRunning
        }
        if NSRunningApplication(processIdentifier: r.item.ownerPID)?.isTerminated ?? true { return .notRunning }
        let tracked = platform.trackedKey(for: r)
        // Through CFPreferences when usable: the plist file lags a live (cfprefsd-notified) write by seconds.
        let allowed = tracked.flatMap { t in
            (platform.liveHideShowAvailable ? (try? ControlCenterTrackedAppsStore.allowedLive([t])) : (try? platform.readAllowed([t])))?[t]
        }
        return .found(ActivationTarget(key: key, ownerPID: r.item.ownerPID, trackedKey: tracked,
                                       frame: r.item.frame, isOnBar: r.item.isOnMenuBar, systemOverflow: r.item.systemOverflow,
                                       element: r.item.axElement, hiddenInControlCenter: allowed == false))
    }

    static func ownerRunning(_ key: ItemKey) -> Bool {
        switch key {
        case .status(let owner, _): return !NSRunningApplication.runningApplications(withBundleIdentifier: owner).isEmpty
        case .heuristic(let b, _, _): return !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty
        case .module: return true
        }
    }

    public func hostedBarCount() async -> Int? {
        // Bounded by wall clock: an AX read can stall while the agent is re-registering scenes right after a hide/show.
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var done = false
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        return await withCheckedContinuation { c in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let src = LiveAccessibilitySource()
                var out: Int?
                if let agent = src.runningApps().first(where: { $0.bundleID == menuBarAgentBundleID }) {
                    let tree = src.agentHostedTree(for: agent, retry: false)
                    if tree.failedReads == 0, tree.unnamedTimeouts == 0, !tree.elements.isEmpty {
                        out = tree.elements.filter { !$0.stale && $0.frame.width > 1 && $0.frame.midY < 30 }.count
                    }
                }
                if once.take() { c.resume(returning: out) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { if once.take() { c.resume(returning: nil) } }
        }
    }

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
        let (down, up, b): (CGEventType, CGEventType, CGMouseButton) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: b),
              let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: b) else { return false }
        d.setIntegerValueField(.mouseEventClickState, value: 1)
        u.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        d.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        u.post(tap: .cghidEventTap)
        return true
    }

    public func axPress(_ t: ActivationTarget) -> Int32 {
        guard let el = t.element else { return AXError.invalidUIElement.rawValue }
        AXUIElementSetMessagingTimeout(el, 2.0)
        return AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue
    }

    /// Menu-ish things currently attached to the item: AXMenu/AXPopover children with a real size, plus the app's AX windows.
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

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let pv = axValue(from: p), let sv = axValue(from: s) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &pt), AXValueGetValue(sv, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}
