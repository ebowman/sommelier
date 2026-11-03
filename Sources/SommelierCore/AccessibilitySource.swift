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
    public init(title: String = "", axDescription: String = "", identifier: String = "",
                frame: CGRect, element: AXUIElement? = nil, stale: Bool = false, staleCount: Int = 0) {
        self.title = title; self.axDescription = axDescription
        self.identifier = identifier; self.frame = frame; self.element = element
        self.stale = stale; self.staleCount = staleCount
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
    public init(stripFrame: CGRect?, elements: [AXElementInfo], failedReads: Int = 0, timedOut: [AXElementInfo] = [],
                unnamedTimeouts: Int = 0) {
        self.stripFrame = stripFrame; self.elements = elements; self.failedReads = failedReads; self.timedOut = timedOut
        self.unnamedTimeouts = unnamedTimeouts
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
    private let cache = AXElementCache()
    public init() {}

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
            c.found.append(r.info)
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
        func run(_ work: [Unchecked<AXUIElement>], timeout: Float, attempts: Int, within: TimeInterval?) -> [Unchecked<AXUIElement>] {
            let parts = boundedParallelMap(work, workers: workers, deadline: within.map { Date().addingTimeInterval($0) }) { w -> Collected in
                var c = Collected()
                self.collect(w.value, depth: 1, timeout: timeout, attempts: attempts, into: &c)
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
        var unresolved = run(tasks, timeout: t, attempts: retry ? 2 : 1, within: overall.map { max(0, $0.timeIntervalSinceNow) })
        trace("pass 1 done, \(unresolved.count) unfinished")
        if retry, !unresolved.isEmpty {
            unresolved = run(unresolved, timeout: agentRetryTimeout, attempts: 2, within: agentRetryWindow)
        }
        // Name what is still missing from the source's memory of those groups (never guessed from elsewhere).
        let unnamed = unresolved.filter { cache.subtree($0.value).isEmpty }.count
        let timedOut = unresolved.flatMap { cache.subtree($0.value) }.map { i -> AXElementInfo in var c = i; c.stale = true; return c }
        if ProcessInfo.processInfo.environment["SOMMELIER_AX_TRACE"] != nil { trace("done: \(found.count) found, \(unresolved.count) groups timed out") }
        return AgentHostedTree(stripFrame: strip, elements: found, failedReads: unresolved.count + topFailed, timedOut: timedOut,
                               unnamedTimeouts: unnamed)
    }
}
