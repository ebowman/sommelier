import AppKit
import ApplicationServices
import Foundation

public let menuBarAgentBundleID = "com.apple.MenuBarAgent"

public struct RunningAppInfo: Sendable, Equatable {
    public var pid: pid_t
    public var bundleID: String?
    public var name: String
    public init(pid: pid_t, bundleID: String?, name: String) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
    }
}

/// Attributes of one AX element the scanner cares about.
public struct AXElementInfo: @unchecked Sendable {
    public var title: String
    public var axDescription: String
    public var identifier: String
    public var frame: CGRect
    public var element: AXUIElement?
    /// Carried forward from an earlier scan rather than read now.
    public var stale: Bool
    /// Consecutive scans this element has been carried forward instead of read.
    public var staleCount: Int
    /// True when the element sits directly under the agent's window, not inside a per-app AXMenuBar group. Only the
    /// agent's own controls do (the overflow chevron, gdu.45); every hosted status item is wrapped in an AXMenuBar.
    public var directWindowChild: Bool
    /// True for an entry of the frontmost app's MAIN menu (Apple, File, Edit, ... and the app-name menu) that MenuBarAgent
    /// mirrors into its tree: role AXMenuBarItem WITHOUT subrole AXMenuExtra, size 0x0 (docs/findings-identity.md, gdu.29).
    /// Set by the live source only; the scanner drops such elements, so they are never items, parked, stale or incomplete.
    public var isMainMenuEntry: Bool
    public init(title: String = "", axDescription: String = "", identifier: String = "",
                frame: CGRect, element: AXUIElement? = nil, stale: Bool = false, staleCount: Int = 0,
                directWindowChild: Bool = false, isMainMenuEntry: Bool = false) {
        self.title = title; self.axDescription = axDescription
        self.identifier = identifier; self.frame = frame; self.element = element
        self.stale = stale; self.staleCount = staleCount; self.directWindowChild = directWindowChild
        self.isMainMenuEntry = isMainMenuEntry
    }

    /// Signature of a main-menu record persisted by a build that did not yet drop them (the cache stores no role): an
    /// empty 0x0 frame with a title and no description. Used only to prune old cache files on load (gdu.29).
    var looksLikeMainMenuRecord: Bool {
        frame.width <= 0 && frame.height <= 0 && !title.isEmpty && axDescription.isEmpty
    }

    /// The agent's overflow chevron. Locale-independent signal first: an AXButton that is a direct child of the agent
    /// window with no identifier and no title (docs/findings-drag.md, "The overflow chevron"). The English
    /// description is only a fallback for trees that do not report the nesting.
    public var isOverflowChevron: Bool {
        if directWindowChild && identifier.isEmpty && title.isEmpty && frame.width > 0 { return true }
        return axDescription == MenuBarItem.overflowChevronName
    }

    /// Identity across scans (frames move): identifier, else description, else frame.
    public var identityKey: String {
        // Titles can be volatile (a "64%" readout), so they are only a last resort before the frame.
        if !identifier.isEmpty { return "id:\(identifier)" }
        if !axDescription.isEmpty { return "desc:\(axDescription)" }
        return "frame:\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))"
    }
}

public struct AgentHostedTree: Sendable {
    /// Frame of the MenuBarAgent AXWindow (the menu bar strip), if found.
    public var stripFrame: CGRect?
    public var elements: [AXElementInfo]
    /// Reads that still failed after all retries (the tree may be incomplete when > 0).
    public var failedReads: Int
    /// Elements whose read specifically timed out (or missed the deadline): their last known values, from the
    /// source's own memory. Only these may be carried forward as stale; an element that is merely absent is gone.
    public var timedOut: [AXElementInfo]
    /// Groups that timed out and that the source has no memory of (e.g. first read in this process). Something
    /// provably failed to read, but not what; the scanner may then carry previously visible items, boundedly.
    public var unnamedTimeouts: Int
    /// Part of `failedReads` that is NOT a per-item group (the window or the top level could not be read). Such a failure
    /// can never be attributed to an item's owner (gdu.51).
    public var topFailures: Int
    /// Set by the scanner (never by a source): every failed/timed-out group is attributable BY IDENTITY to a self-positioning
    /// owner (gdu.51), so the read is complete for everyone else.
    public var failuresAreSelfPositioning = false
    /// Set by the scanner when failures exist and are NOT attributable to self-positioning owners: why (gdu.51 diagnosability).
    public var incompleteReason: String?
    public init(stripFrame: CGRect?, elements: [AXElementInfo], failedReads: Int = 0, timedOut: [AXElementInfo] = [],
                unnamedTimeouts: Int = 0, topFailures: Int = 0) {
        self.stripFrame = stripFrame; self.elements = elements; self.failedReads = failedReads; self.timedOut = timedOut
        self.unnamedTimeouts = unnamedTimeouts; self.topFailures = topFailures
        if failedReads > 0, topFailures == 0, timedOut.isEmpty, unnamedTimeouts == 0 { self.topFailures = failedReads }
    }
}

/// Minimal Accessibility surface the scanner needs; fixtures implement it in tests.
public enum ExtrasRead: @unchecked Sendable {
    /// The read succeeded (possibly with no items).
    case items([AXElementInfo])
    /// The read errored or timed out; the reason is for logging.
    case failed(String)
}

public extension AccessibilitySource {
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead { .items(extrasItems(for: app)) }
    func agentHostedTree(for agent: RunningAppInfo, retry: Bool) -> AgentHostedTree { agentHostedTree(for: agent) }
    func noteUnresolvedGroups(selfPositioning: Bool) {}
}

/// Implementations must be safe to call concurrently from multiple threads (the scanner queries apps in parallel).
public protocol AccessibilitySource: Sendable {
    /// PID of the current process (for self-exclusion).
    var currentPID: pid_t { get }
    func runningApps() -> [RunningAppInfo]
    /// Children of the app's `AXExtrasMenuBar`. Empty when denied, absent or timed out.
    func extrasItems(for app: RunningAppInfo) -> [AXElementInfo]
    /// Like `extrasItems` but distinguishes "no extras" from a failed/timed-out read.
    /// `timeout` (seconds) overrides the default per-element messaging timeout when non-nil.
    func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead
    /// Elements hosted by MenuBarAgent. Empty tree when unavailable.
    func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree
    /// `retry: false` is the latency-bound variant used by the fast path: one short pass, no retry round; nodes that
    /// time out are reported in `failedReads` and the scanner carries them forward from the previous scan.
    func agentHostedTree(for agent: RunningAppInfo, retry: Bool) -> AgentHostedTree
    /// Scanner feedback after a retrying read (gdu.51): the groups that did not finish were all attributed, by identity, to
    /// self-positioning owners (true) or not (false). Only attributed groups may be read with a short capped timeout.
    func noteUnresolvedGroups(selfPositioning: Bool)
}

/// Thread-safe cache of per-pid AX elements (application element and its AXExtrasMenuBar element).
/// Entries are dropped on NSWorkspace launch/terminate (when a run loop delivers them), when a pid vanishes from
/// `runningApps()`, and when MenuBarAgent's pid changes.
final class AXElementCache: @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [pid_t: AXUIElement] = [:]
    private var extras: [pid_t: AXUIElement] = [:]
    private var knownPIDs: Set<pid_t> = []
    private var agentPID: pid_t?
    private var tokens: [NSObjectProtocol] = []
    private var subtrees: [ElementKey: [AXElementInfo]] = [:]

    struct ElementKey: Hashable {
        let e: AXUIElement
        func hash(into h: inout Hasher) { h.combine(CFHash(e)) }
        static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.e, b.e) }
    }
    /// Last fully-read hosted items under one agent group, used to name what timed out next time.
    func setSubtree(_ e: AXUIElement, _ items: [AXElementInfo]) {
        lock.lock(); defer { lock.unlock() }
        if subtrees.count > 512 { subtrees.removeAll() }
        subtrees[ElementKey(e: e)] = items.map { var i = $0; i.element = nil; return i }
    }
    func subtree(_ e: AXUIElement) -> [AXElementInfo] { lock.lock(); defer { lock.unlock() }; return subtrees[ElementKey(e: e)] ?? [] }

    /// Agent groups whose last full (retrying) read did not finish: the next read gives them a short timeout and no retry
    /// round (gdu.51), so one slow owner (iStat) does not cost every scan the whole retry budget.
    private var slow: Set<ElementKey> = []
    private var slowReads = 0
    /// The subset of `slow` the scanner attributed, by identity, to self-positioning owners. ONLY these get the short cap;
    /// every other group keeps the normal retry round (a healthy slow group must be able to finish).
    private var spSlow: Set<ElementKey> = []
    /// Hysteresis (gdu.81): attributed groups stay capped until this time even across reads that resolve them, so an iStat
    /// that alternates answering and stalling does not re-pay the whole retry budget on every first stale read.
    private var capUntil: [ElementKey: Date] = [:]
    func isCapped(_ e: AXUIElement, at now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = ElementKey(e: e)
        return spSlow.contains(k) || (capUntil[k].map { $0 > now } ?? false)
    }
    /// The scanner's verdict on the groups that did not finish in the last read: all attributed to self-positioning owners
    /// (they become capped) or not (nobody is capped).
    /// `hysteresis` > 0 (gdu.81) additionally keeps each attributed group capped until `now + hysteresis`, refreshed every time
    /// a read leaves it unresolved; 0 is the pre-gdu.81 behaviour (the cap ends with the first read that resolves the group).
    /// A read with any unattributed failure still caps nobody.
    func noteUnresolvedAttribution(selfPositioning: Bool, hysteresis: TimeInterval = 0, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        capUntil = capUntil.filter { $0.value > now }
        if !selfPositioning { capUntil = [:] }
        else if hysteresis > 0 { for k in slow { capUntil[k] = now.addingTimeInterval(hysteresis) } }
        // Identity persists in the scanner's record, so attribution (and with it the cap) holds for a whole streak; a read
        // with any unattributed failure caps nobody (gdu.51), and a group leaves the set when a read resolves it (`setSlow`).
        spSlow = selfPositioning ? slow : []
    }
    /// Every 5th full read gives slow groups one attempt with the normal first-pass timeout (still no retry round), so a group
    /// that merely needs a bit more than the cap is refreshed regularly at a bounded cost.
    var slowRefreshRead: Bool { lock.lock(); defer { lock.unlock() }; return slowReads % 5 == 4 }
    func setSlow(_ groups: [AXUIElement]) {
        lock.lock(); defer { lock.unlock() }
        slow = Set(groups.map { ElementKey(e: $0) })
        spSlow.formIntersection(slow)
        slowReads += 1
    }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
                if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.evict(app.processIdentifier)
                }
            })
        }
    }
    deinit { for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) } }

    func app(_ pid: pid_t) -> AXUIElement {
        lock.lock(); defer { lock.unlock() }
        if let e = apps[pid] { return e }
        let e = AXUIElementCreateApplication(pid)
        apps[pid] = e
        return e
    }
    func cachedExtras(_ pid: pid_t) -> AXUIElement? { lock.lock(); defer { lock.unlock() }; return extras[pid] }
    func setExtras(_ pid: pid_t, _ e: AXUIElement) { lock.lock(); extras[pid] = e; lock.unlock() }
    func evict(_ pid: pid_t) { lock.lock(); apps[pid] = nil; extras[pid] = nil; lock.unlock() }
    /// Drops entries for pids that are no longer running (missed terminate notification).
    func prune(running: Set<pid_t>) {
        lock.lock(); defer { lock.unlock() }
        for pid in knownPIDs.subtracting(running) { apps[pid] = nil; extras[pid] = nil }
        knownPIDs = running
    }
    func noteAgent(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if let old = agentPID, old != pid { apps[old] = nil; extras[old] = nil; subtrees.removeAll() }
        agentPID = pid
    }
    var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return apps.count }
}

/// AX values are CF types; check the type id instead of force-casting.
func axElement(from v: AnyObject?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}

func axValue(from v: AnyObject?) -> AXValue? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    return unsafeBitCast(v, to: AXValue.self)
}

/// Real implementation on top of ApplicationServices.
public struct LiveAccessibilitySource: AccessibilitySource {
    public var messagingTimeout: Float = 0.25
    /// MenuBarAgent is the authoritative visible set, so it gets a longer timeout.
    public var agentTimeout: Float = 0.5
    /// Timeout for the single retry round over agent nodes whose first read timed out.
    public var agentRetryTimeout: Float = 1.0
    /// Wall-clock cap for the retry round; nodes unfinished by then are reported as failed.
    public var agentRetryWindow: TimeInterval = 1.2
    /// Max concurrent element reads while walking the MenuBarAgent tree.
    public var agentWorkers = 8
    /// Timeout for an agent group that did not finish in the previous full read (gdu.51); such a group is not retried.
    /// 0 disables the cap.
    public var agentSlowGroupTimeout: Float = 0.3
    /// gdu.81: seconds a self-positioning group stays capped after the last read that left it unresolved, across reads that
    /// resolve it (the periodic normal-timeout probe still runs). 0 restores the pre-gdu.81 behaviour.
    public var slowGroupHysteresis: TimeInterval = 60
    private let cache = AXElementCache()
    public init() {}

    public func noteUnresolvedGroups(selfPositioning: Bool) { cache.noteUnresolvedAttribution(selfPositioning: selfPositioning, hysteresis: slowGroupHysteresis) }

    public var currentPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    public func runningApps() -> [RunningAppInfo] {
        // .prohibited apps (XPC services, extensions, helpers) cannot own status items; measured 0 of ~110
        // exposing AXExtrasMenuBar, and each costs 40-260 ms. .accessory and .regular are kept.
        let apps = NSWorkspace.shared.runningApplications
        cache.prune(running: Set(apps.map(\.processIdentifier)))
        return apps.filter { $0.activationPolicy != .prohibited }.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                           name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)")
        }
    }

    private static var infoAttrs: [CFString] { [
        kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
        kAXIdentifierAttribute as CFString, kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString, kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString,
    ] }

    private func copy(_ e: AXUIElement, _ a: String) -> (AnyObject?, AXError) {
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(e, a as CFString, &v)
        return (r == .success ? v : nil, r)
    }

    /// Children, retrying on cannotComplete (timeout). Returns nil if still failing.
    private func children(_ e: AXUIElement, attempts: Int = 1) -> [AXUIElement]? {
        for _ in 0..<attempts {
            let (v, r) = copy(e, kAXChildrenAttribute)
            if let arr = v as? [AnyObject] { return arr.compactMap { axElement(from: $0) } }
            if r != .cannotComplete { return [] }  // permanent (no children, API disabled, ...): retrying is pointless
        }
        return nil
    }

    /// Number of per-item groups under the MenuBarAgent's windows: a top-level read only (no descent into the owners), so it
    /// answers in milliseconds where the full hosted read takes 0.03-7 s. nil when any level could not be read in `timeout`.
    /// Hidden items have no group at all (docs/findings-live-trigger.md); a revealed one gets one.
    public func hostedGroupCount(agentPID: pid_t, timeout: Float = 0.3) -> Int? {
        let ax = cache.app(agentPID)
        AXUIElementSetMessagingTimeout(ax, timeout)
        guard let windows = children(ax, attempts: 1) else { return nil }
        var n = 0
        for w in windows {
            AXUIElementSetMessagingTimeout(w, timeout)
            guard let kids = children(w, attempts: 1) else { return nil }
            n += kids.count
        }
        return n
    }

    /// The agent's overflow chevron and the stacked/hosted frames, from TOP-LEVEL reads only (milliseconds, no descent into the
    /// owners): the chevron is the agent window's direct AXButton child without identifier or title (the English description is
    /// the fallback, as in `AXElementInfo.isOverflowChevron`); every other direct window child is one hosted group. `expanded`:
    /// the chevron is open ("Hide Menu Bar Items"), which shows as the menu-extras strip (the agent's AXMenuBar) starting LEFT
    /// of the chevron instead of right behind it (gdu.65). nil when any level could not be read in `timeout`.
    public func overflowProbe(agentPID: pid_t, timeout: Float = 0.3) -> OverflowProbe? {
        let ax = cache.app(agentPID)
        AXUIElementSetMessagingTimeout(ax, timeout)
        guard let tops = children(ax, attempts: 1) else { return nil }
        func rect(_ e: AXUIElement) -> CGRect? {
            AXUIElementSetMessagingTimeout(e, timeout)
            let (p, _) = copy(e, kAXPositionAttribute), (s, _) = copy(e, kAXSizeAttribute)
            guard let pv = axValue(from: p), let sv = axValue(from: s) else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            guard AXValueGetValue(pv, .cgPoint, &pt), AXValueGetValue(sv, .cgSize, &sz) else { return nil }
            return CGRect(origin: pt, size: sz)
        }
        func str(_ e: AXUIElement, _ a: String) -> String { (copy(e, a).0 as? String) ?? "" }
        var chevron: CGRect?
        var hosted: [CGRect] = []
        var stripMinX: CGFloat?
        for t in tops {
            AXUIElementSetMessagingTimeout(t, timeout)
            if str(t, kAXRoleAttribute) == "AXMenuBar" { stripMinX = rect(t)?.minX; continue }
            guard let kids = children(t, attempts: 1) else { return nil }
            for k in kids {
                guard let f = rect(k) else { return nil }
                let isChevron = str(k, kAXRoleAttribute) == "AXButton"
                    && ((str(k, kAXIdentifierAttribute).isEmpty && str(k, kAXTitleAttribute).isEmpty)
                        || str(k, kAXDescriptionAttribute) == MenuBarItem.overflowChevronName)
                if isChevron { chevron = f } else if f.width > 1 { hosted.append(f) }
            }
        }
        let expanded = chevron.map { c in stripMinX.map { $0 < c.minX - 2 } ?? false } ?? false
        return OverflowProbe(chevron: chevron, expanded: expanded, hosted: hosted)
    }

    private struct ReadResult { var info: AXElementInfo; var role: String; var subrole: String; var ok: Bool; var err: Int32 = 0
        /// Worth retrying: a timeout. Other errors (e.g. apiDisabled -25211) are permanent for that element.
        var transient: Bool { !ok && err == AXError.cannotComplete.rawValue }
    }

    /// Reads all needed attributes in one IPC round trip.
    private func read(_ e: AXUIElement, timeout: Float) -> ReadResult {
        AXUIElementSetMessagingTimeout(e, timeout)
        var out: CFArray?
        var vals: [AnyObject?] = Array(repeating: nil, count: Self.infoAttrs.count)
        let rc = AXUIElementCopyMultipleAttributeValues(e, Self.infoAttrs as CFArray, [], &out)
        let ok = rc == .success
        if ok, let arr = out as? [AnyObject] {
            for (i, v) in arr.enumerated() where i < vals.count { vals[i] = v }
        }
        func s(_ i: Int) -> String { (vals[i] as? String) ?? "" }
        var p = CGPoint.zero, sz = CGSize.zero
        if let pv = axValue(from: vals[3]) { AXValueGetValue(pv, .cgPoint, &p) }
        if let sv = axValue(from: vals[4]) { AXValueGetValue(sv, .cgSize, &sz) }
        return ReadResult(info: AXElementInfo(title: s(0), axDescription: s(1), identifier: s(2),
                                              frame: CGRect(origin: p, size: sz), element: e),
                          role: s(5), subrole: s(6), ok: ok, err: rc.rawValue)
    }

    /// Re-reads while the frame is empty (timeouts are not retried in place: each costs a full timeout, the caller's retry
    /// round handles them). An empty frame is only retried for
    /// elements that should have one (menu extras, untitled buttons): app menu titles are legitimately zero-sized.
    private func readRetrying(_ e: AXUIElement, timeout: Float, attempts: Int) -> ReadResult {
        func needsRetry(_ r: ReadResult) -> Bool {
            (r.ok && (r.info.frame.width <= 0 || r.info.frame.height <= 0) && (r.subrole == "AXMenuExtra" || r.info.title.isEmpty))
        }
        var last = read(e, timeout: timeout)
        var n = 1
        while n < attempts && needsRetry(last) { last = read(e, timeout: timeout); n += 1 }
        return last
    }

    public func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] {
        if case .items(let i) = readExtras(for: app, timeout: nil) { return i }
        return []
    }

    public func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        // WebKit renderer/network helpers never host menu extras and each costs a full timeout.
        if let id = app.bundleID, id.hasPrefix("com.apple.WebKit.") { return .items([]) }
        let t = timeout ?? messagingTimeout
        var usedCache = cache.cachedExtras(app.pid) != nil
        while true {
            let extrasEl: AXUIElement
            if let cached = cache.cachedExtras(app.pid) {
                extrasEl = cached
                AXUIElementSetMessagingTimeout(extrasEl, t)
            } else {
                let ax = cache.app(app.pid)
                AXUIElementSetMessagingTimeout(ax, t)
                let (extras, r) = copy(ax, "AXExtrasMenuBar")
                guard let extras else {
                    switch r {
                    case .noValue, .attributeUnsupported, .invalidUIElement: return .items([])
                    case .cannotComplete: return .failed("timed out (kAXErrorCannotComplete)")
                    default: return .failed("AX error \(r.rawValue)")
                    }
                }
                guard let el = axElement(from: extras) else { return .failed("AXExtrasMenuBar is not an AXUIElement") }
                extrasEl = el
                cache.setExtras(app.pid, el)
            }
            if let kids = children(extrasEl, attempts: 2) {
                return .items(kids.map { readRetrying($0, timeout: t, attempts: 2).info })
            }
            if usedCache {
                // The cached element may have gone stale (app rebuilt its status items); redo from the app element.
                cache.evict(app.pid)
                usedCache = false
                continue
            }
            return .failed("could not read extras children")
        }
    }

    private struct Collected: @unchecked Sendable {
        var found: [AXElementInfo] = []
        var strip: CGRect?
        var failed: [(Unchecked<AXUIElement>, Int)] = []
    }

    /// Walks one subtree sequentially. Nodes whose read or children fetch fails are returned in `failed` for a retry.
    private func collect(_ e: AXUIElement, depth: Int, timeout t: Float, attempts: Int, into c: inout Collected) {
        let hostedRoles: Set<String> = ["AXMenuBarItem", "AXButton", "AXMenuButton", "AXStatusItem"]
        let r = readRetrying(e, timeout: t, attempts: attempts)
        if r.transient {
            c.failed.append((Unchecked(value: e), depth))
            if ProcessInfo.processInfo.environment["SOMMELIER_AX_TRACE"] != nil {
                FileHandle.standardError.write(Data("read failed depth \(depth) err \(r.err) t=\(t)\n".utf8))
            }
        }
        // A timed-out node is re-read, subtree included, by the retry round: don't spend more timeouts below it.
        if r.transient { return }
        if r.role == "AXWindow" {
            if c.strip == nil, r.info.frame.width > 0 { c.strip = r.info.frame }
        } else if hostedRoles.contains(r.role) {
            var info = r.info
            info.directWindowChild = depth == 1 && r.role == "AXButton"
            // The frontmost app's main menu is mirrored here as AXMenuBarItem with NO AXMenuExtra subrole (gdu.29); every
            // hosted status item is either an AXMenuExtra or an AXButton. The 0x0 check guards against a subrole read that failed alone.
            info.isMainMenuEntry = r.role == "AXMenuBarItem" && r.subrole != "AXMenuExtra" && info.frame.size == .zero
            c.found.append(info)
        }
        guard depth < 4 else { return }
        guard let kids = children(e, attempts: 1) else {
            c.failed.append((Unchecked(value: e), depth))
            return
        }
        for k in kids.prefix(80) { collect(k, depth: depth + 1, timeout: t, attempts: attempts, into: &c) }
    }

    /// Hosted items are the authoritative visible set: long timeout, retry any failed or empty-frame read.
    /// The window's per-item groups are read in parallel (MenuBarAgent forwards each query to the owning app, so
    /// one slow app no longer serialises the whole walk); nodes that still fail are re-read with growing timeouts.
    public func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree { agentHostedTree(for: agent, retry: true) }

    /// Per-element timeout of the fast (no retry) variant.
    public var agentFastTimeout: Float = 0.3
    /// Overall wall-clock deadline of the fast variant; groups still unread then are reported in `timedOut`.
    public var agentFastDeadline: TimeInterval = 0.3

    /// Hosted items are the authoritative visible set. The window's per-item groups are read in parallel (MenuBarAgent
    /// forwards each query to the owning app, so one slow app must not serialise the walk). With `retry` the groups
    /// that timed out are re-read once with a longer timeout; without it the whole read ends at `agentFastDeadline`.
    /// Groups still unread are returned as `timedOut` (their last known items) for the scanner to carry forward.
    public func agentHostedTree(for agent: RunningAppInfo, retry: Bool) -> AgentHostedTree {
        cache.noteAgent(agent.pid)
        let t0 = Date()
        func trace(_ m: String) {
            if ProcessInfo.processInfo.environment["SOMMELIER_AX_TRACE"] != nil {
                FileHandle.standardError.write(Data("  agent \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(m)\n".utf8))
            }
        }
        let t = retry ? agentTimeout : agentFastTimeout
        let overall: Date? = retry ? nil : t0.addingTimeInterval(agentFastDeadline)
        let workers = retry ? agentWorkers : max(agentWorkers, 16)
        let topAttempts = retry ? 3 : 1
        let ax = cache.app(agent.pid)
        AXUIElementSetMessagingTimeout(ax, t)
        guard let windows = children(ax, attempts: topAttempts) else {
            return AgentHostedTree(stripFrame: nil, elements: [], failedReads: 1)
        }
        var found: [AXElementInfo] = []
        var strip: CGRect?
        var topFailed = 0
        var tasks: [Unchecked<AXUIElement>] = []
        for w in windows {
            let r = readRetrying(w, timeout: t, attempts: topAttempts)
            if r.transient { topFailed += 1 }
            if r.role == "AXWindow", strip == nil, r.info.frame.width > 0 { strip = r.info.frame }
            guard let kids = children(w, attempts: topAttempts) else { topFailed += 1; continue }
            tasks += kids.prefix(80).map { Unchecked(value: $0) }
        }
        trace("top level read, \(tasks.count) tasks")

        /// Reads whole groups in parallel; returns the groups that did not finish cleanly (timed out, unfinished at
        /// the deadline, or containing a node that timed out).
        func run(_ work: [Unchecked<AXUIElement>], timeout: Float, attempts: Int, within: TimeInterval?, slowCap: Bool = false) -> [Unchecked<AXUIElement>] {
            let capped = slowCap && agentSlowGroupTimeout > 0
            let refresh = cache.slowRefreshRead
            // gdu.83: capped (known-slow) groups each wait out their short timeout; give them workers of their own so they do
            // not queue the healthy groups behind them in extra 0.3 s waves (9 stalled groups on 8 workers cost three waves).
            let workers = capped ? workers + work.filter { self.cache.isCapped($0.value) }.count : workers
            let parts = boundedParallelMap(work, workers: workers, deadline: within.map { Date().addingTimeInterval($0) }) { w -> Collected in
                var c = Collected()
                let isSlow = capped && self.cache.isCapped(w.value)
                self.collect(w.value, depth: 1, timeout: isSlow && !refresh ? min(timeout, self.agentSlowGroupTimeout) : timeout,
                             attempts: isSlow ? 1 : attempts, into: &c)
                return c
            }
            var unfinished: [Unchecked<AXUIElement>] = []
            for (w, part) in zip(work, parts) {
                guard let p = part else { unfinished.append(w); continue }
                found += p.found
                if strip == nil { strip = p.strip }
                if p.failed.isEmpty { cache.setSubtree(w.value, p.found) } else { unfinished.append(w) }
            }
            return unfinished
        }
        var unresolved = run(tasks, timeout: t, attempts: retry ? 2 : 1, within: overall.map { max(0, $0.timeIntervalSinceNow) }, slowCap: retry)
        trace("pass 1 done, \(unresolved.count) unfinished")
        if retry, !unresolved.isEmpty {
            // Groups that were already slow last time had their short pass; only the others get the long retry round.
            let fresh = unresolved.filter { !cache.isCapped($0.value) || agentSlowGroupTimeout <= 0 }
            let stillSlow = unresolved.filter { cache.isCapped($0.value) && agentSlowGroupTimeout > 0 }
            unresolved = stillSlow + (fresh.isEmpty ? [] : run(fresh, timeout: agentRetryTimeout, attempts: 2, within: agentRetryWindow))
        }
        if retry { cache.setSlow(unresolved.map(\.value)) }
        // Name what is still missing from the source's memory of those groups (never guessed from elsewhere).
        let unnamed = unresolved.filter { cache.subtree($0.value).isEmpty }.count
        let timedOut = unresolved.flatMap { cache.subtree($0.value) }.map { i -> AXElementInfo in var c = i; c.stale = true; return c }
        if ProcessInfo.processInfo.environment["SOMMELIER_AX_TRACE"] != nil {
            for (i, w) in tasks.enumerated() where unresolved.contains(where: { $0.value == w.value }) {
                AXUIElementSetMessagingTimeout(w.value, 0.2)
                let r = readRetrying(w.value, timeout: 0.2, attempts: 1)
                let kids = children(w.value, attempts: 1)
                trace("UNRESOLVED group #\(i) role=\(r.role) frame=\(r.info.frame) id='\(r.info.identifier)' desc='\(r.info.axDescription)' title='\(r.info.title)' err=\(r.err) kids=\(kids.map { String($0.count) } ?? "nil") cached=\(cache.subtree(w.value).count)")
            }
        }
        if ProcessInfo.processInfo.environment["SOMMELIER_AX_TRACE"] != nil { trace("done: \(found.count) found, \(unresolved.count) groups timed out") }
        return AgentHostedTree(stripFrame: strip, elements: found, failedReads: unresolved.count + topFailed, timedOut: timedOut,
                               unnamedTimeouts: unnamed, topFailures: topFailed)
    }
}
