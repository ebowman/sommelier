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
    public init(title: String = "", axDescription: String = "", identifier: String = "",
                frame: CGRect, element: AXUIElement? = nil) {
        self.title = title; self.axDescription = axDescription
        self.identifier = identifier; self.frame = frame; self.element = element
    }
}

public struct AgentHostedTree: Sendable {
    /// Frame of the MenuBarAgent AXWindow (the menu bar strip), if found.
    public var stripFrame: CGRect?
    public var elements: [AXElementInfo]
    public init(stripFrame: CGRect?, elements: [AXElementInfo]) {
        self.stripFrame = stripFrame; self.elements = elements
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
}

/// Real implementation on top of ApplicationServices.
public struct LiveAccessibilitySource: AccessibilitySource {
    public var messagingTimeout: Float = 0.25
    /// MenuBarAgent is the authoritative visible set, so it gets a longer timeout.
    public var agentTimeout: Float = 1.0
    public init() {}

    public var currentPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    public func runningApps() -> [RunningAppInfo] {
        // .prohibited apps (XPC services, extensions, helpers) cannot own status items; measured 0 of ~110
        // exposing AXExtrasMenuBar, and each costs 40-260 ms. .accessory and .regular are kept.
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }.map {
            RunningAppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                           name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)")
        }
    }

    private static var infoAttrs: [CFString] { [
        kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
        kAXIdentifierAttribute as CFString, kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString, kAXRoleAttribute as CFString,
    ] }

    private func appElement(_ pid: pid_t, timeout: Float) -> AXUIElement {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, timeout)
        return ax
    }

    private func copy(_ e: AXUIElement, _ a: String) -> (AnyObject?, AXError) {
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(e, a as CFString, &v)
        return (r == .success ? v : nil, r)
    }

    /// Children, retrying on cannotComplete (timeout). Returns nil if still failing.
    private func children(_ e: AXUIElement, attempts: Int = 1) -> [AXUIElement]? {
        for _ in 0..<attempts {
            let (v, r) = copy(e, kAXChildrenAttribute)
            if let kids = v as? [AXUIElement] { return kids }
            if r != .cannotComplete { return r == .success || r == .noValue || r == .attributeUnsupported ? [] : nil }
        }
        return nil
    }

    /// Reads all needed attributes in one IPC round trip. Returns (info, role, ok).
    private func read(_ e: AXUIElement, timeout: Float) -> (AXElementInfo, String, Bool) {
        AXUIElementSetMessagingTimeout(e, timeout)
        var out: CFArray?
        var vals: [AnyObject?] = Array(repeating: nil, count: Self.infoAttrs.count)
        let ok = AXUIElementCopyMultipleAttributeValues(e, Self.infoAttrs as CFArray, [], &out) == .success
        if ok, let arr = out as? [AnyObject] {
            for (i, v) in arr.enumerated() where i < vals.count { vals[i] = v }
        }
        func s(_ i: Int) -> String { (vals[i] as? String) ?? "" }
        var p = CGPoint.zero, sz = CGSize.zero
        if let pv = vals[3], CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        }
        if let sv = vals[4], CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        }
        return (AXElementInfo(title: s(0), axDescription: s(1), identifier: s(2),
                              frame: CGRect(origin: p, size: sz), element: e), s(5), ok)
    }

    /// Read with retries until the call succeeds and the frame is non-empty.
    private func readRetrying(_ e: AXUIElement, timeout: Float, attempts: Int) -> (AXElementInfo, String) {
        var last = read(e, timeout: timeout)
        var n = 1
        while n < attempts && (!last.2 || last.0.frame.width <= 0 || last.0.frame.height <= 0) {
            last = read(e, timeout: timeout)
            n += 1
        }
        return (last.0, last.1)
    }

    public func extrasItems(for app: RunningAppInfo) -> [AXElementInfo] {
        if case .items(let i) = readExtras(for: app, timeout: nil) { return i }
        return []
    }

    public func readExtras(for app: RunningAppInfo, timeout: Float?) -> ExtrasRead {
        // WebKit renderer/network helpers never host menu extras and each costs a full timeout.
        if let id = app.bundleID, id.hasPrefix("com.apple.WebKit.") { return .items([]) }
        let t = timeout ?? messagingTimeout
        let ax = appElement(app.pid, timeout: t)
        let (extras, r) = copy(ax, "AXExtrasMenuBar")
        guard let extras else {
            switch r {
            case .noValue, .attributeUnsupported, .invalidUIElement: return .items([])
            case .cannotComplete: return .failed("timed out (kAXErrorCannotComplete)")
            default: return .failed("AX error \(r.rawValue)")
            }
        }
        guard let kids = children(extras as! AXUIElement, attempts: 2) else {
            return .failed("could not read extras children")
        }
        return .items(kids.map { readRetrying($0, timeout: t, attempts: 2).0 })
    }

    /// Hosted items are the authoritative visible set: long timeout, retry any failed or empty-frame read.
    public func agentHostedTree(for agent: RunningAppInfo) -> AgentHostedTree {
        let t = agentTimeout
        let ax = appElement(agent.pid, timeout: t)
        var strip: CGRect?
        var found: [AXElementInfo] = []
        let hostedRoles: Set<String> = ["AXMenuBarItem", "AXButton", "AXMenuButton", "AXStatusItem"]
        func walk(_ e: AXUIElement, depth: Int) {
            let (info, role) = readRetrying(e, timeout: t, attempts: 3)
            if role == "AXWindow" {
                if strip == nil, info.frame.width > 0 { strip = info.frame }
            } else if hostedRoles.contains(role) {
                found.append(info)
            }
            guard depth < 4, let kids = children(e, attempts: 3) else { return }
            for k in kids.prefix(80) { walk(k, depth: depth + 1) }
        }
        for w in children(ax, attempts: 3) ?? [] { walk(w, depth: 0) }
        return AgentHostedTree(stripFrame: strip, elements: found)
    }
}
