import AppKit
import ApplicationServices
import Foundation

public struct MenuProbe: Equatable, Sendable {
    /// The item exposes an AXMenu child.
    public var hasMenu: Bool
    /// Number of AX windows of the owning app.
    public var windowCount: Int
    public init(hasMenu: Bool, windowCount: Int) { self.hasMenu = hasMenu; self.windowCount = windowCount }
}

public struct AgentRestartOutcome: Equatable, Sendable {
    public var recovered: Bool
    public var elapsedMS: Int
    public init(recovered: Bool, elapsedMS: Int) { self.recovered = recovered; self.elapsedMS = elapsedMS }
}

/// Everything `LiveActuator` needs from the machine. `LivePlatform` is the real implementation; tests inject fakes.
public protocol ActuatorPlatform: SnapshotScanning {
    func accessibilityTrusted() -> Bool
    func pressedMouseButtons() -> Int
    /// Description of a running competing manager (e.g. "Bartender 7 is running"), nil when none.
    func conflictingManager() -> String?
    func resolve(_ snapshot: MenuBarSnapshot) -> [ResolvedItem]
    /// Control Center `trackedApplications` key for this item's app, nil when macOS has no entry (item cannot be hidden).
    func trackedKey(for item: ResolvedItem) -> String?
    /// Cmd+drag of the item's center to `toX`; returns when the mouse-up was posted. Throws `DragError`.
    func drag(itemFrame: CGRect, toX: CGFloat, steps: Int) async throws -> Date
    func menuProbe(for item: MenuBarItem) -> MenuProbe
    func pressEscape()
    func readOrderStore() throws -> [String: Double]
    /// `allowModules` is only for writing back values the agent itself re-based (restoring a pre-restart layout).
    func writeOrderStore(_ updates: [String: Double], allowModules: Bool) throws
    /// Waits until the agent's order-store file has not changed for ~1 s (bounded).
    func waitForOrderStoreQuiet() async
    /// ONE atomic write of all `isAllowed` flags (keys are `trackedKey`s).
    func writeAllowed(_ changes: [String: Bool]) throws
    func readAllowed(_ keys: [String]) throws -> [String: Bool]
    /// True when the cfprefsd-notified write is usable (this process has the app-group entitlement). Decided BEFORE writing:
    /// an unentitled CFPreferences write silently lands in the wrong file.
    var liveHideShowAvailable: Bool { get }
    /// Live (CFPreferences, cfprefsd-notified) variant of `writeAllowed`; MenuBarAgent applies it without a respawn.
    func setAllowedLive(_ changes: [String: Bool]) throws
    /// `expectedChange`: hosted items expected to appear/disappear because of the restart (see `MenuBarAgentControl.restart`).
    func restartAgent(timeout: TimeInterval, expectedChange: Int) async -> AgentRestartOutcome
    func sleep(_ seconds: TimeInterval) async
    func now() -> Date
    /// Number of items MenuBarAgent hosts on the strip right now; nil when the read was incomplete (of7 write-time evidence).
    func hostedBarCount() async -> Int?
    /// The hosted tree right now (complete read only, retrying), left to right, unattributed; nil when no complete read.
    func hostedLayout() async -> [HostedEntry]?
    /// The scanner's last complete attributed hosted tree if it is at most `maxAge` seconds old.
    func recentCompleteHostedLayout(maxAge: TimeInterval) -> [HostedEntry]?
    /// Records that these owners' identifier-less items were live-hidden by us and confirmed by a hosted-count drop.
    func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?)
    /// Forgets the assumed-hidden state of these owners (show, respawn, failed attempt).
    func clearAssumedHidden(pids: Set<pid_t>)
}

public struct AssumedHiddenOwner: Equatable, Sendable {
    public var pid: pid_t
    public var bundleID: String?
    /// Number of the owner's items that were on the bar before the hide.
    public var items: Int
    /// Control Center tracked key of the unit (for the `isAllowed` readback that detects a show by someone else).
    public var trackedKey: String?
    public init(pid: pid_t, bundleID: String?, items: Int, trackedKey: String? = nil) {
        self.pid = pid; self.bundleID = bundleID; self.items = items; self.trackedKey = trackedKey
    }
}

extension ActuatorPlatform {
    public func hostedBarCount() async -> Int? { nil }
    public func hostedLayout() async -> [HostedEntry]? { nil }
    public func recentCompleteHostedLayout(maxAge: TimeInterval) -> [HostedEntry]? { nil }
    public func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?) {}
    public func clearAssumedHidden(pids: Set<pid_t>) {}
}

private final class ScannerBox: @unchecked Sendable { let v: MenuBarScanner; init(_ v: MenuBarScanner) { self.v = v } }

/// Real machine: AX scanner, CGEvent drags, plist stores, `killall MenuBarAgent`.
public final class LivePlatform: ActuatorPlatform, @unchecked Sendable {
    public static let bartenderBundleID = "com.surteesstudios.Bartender"
    private let scanner: MenuBarScanner
    private let resolver: IdentityResolver
    private let work = DispatchQueue(label: "sommelier.liveplatform", qos: .userInitiated)

    public init(scanner: MenuBarScanner = MenuBarScanner(cacheURL: MenuBarScanner.defaultCacheURL),
                resolver: IdentityResolver = IdentityResolver()) {
        self.scanner = scanner
        self.resolver = resolver
    }

    private func onWork<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in work.async { c.resume(returning: body()) } }
    }

    public func scanVisible() async -> MenuBarSnapshot {
        let s = ScannerBox(scanner)
        // A cold scanner has no owner-attribution cache: the fast path would mislabel everything.
        return await onWork { s.v.isWarm ? s.v.scanVisible() : s.v.scan() }
    }

    public func scan() async -> MenuBarSnapshot {
        let s = ScannerBox(scanner)
        return await onWork { s.v.scan() }
    }

    public func accessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    public func pressedMouseButtons() -> Int { Int(NSEvent.pressedMouseButtons) }

    public func conflictingManager() -> String? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bartenderBundleID)
            .contains { !$0.isTerminated }
        return running ? "Bartender 7 is running" : nil
    }

    public func resolve(_ snapshot: MenuBarSnapshot) -> [ResolvedItem] { resolver.resolve(snapshot: snapshot) }

    public func trackedKey(for item: ResolvedItem) -> String? {
        guard let entries = try? ControlCenterTrackedAppsStore().entries() else { return nil }
        let keys = Set(entries.map(\.key))
        for c in [item.item.ownerBundleID, item.ownerKey].compactMap({ $0 }) where keys.contains(c) { return c }
        return nil
    }

    public func drag(itemFrame: CGRect, toX: CGFloat, steps: Int) async throws -> Date {
        let result: Result<Date, DragError> = await onWork {
            do { return .success(try DragMover(steps: steps).move(itemFrame: itemFrame, toX: toX)) }
            catch let e as DragError { return .failure(e) }
            catch { return .failure(.eventCreationFailed) }
        }
        return try result.get()
    }

    public func menuProbe(for item: MenuBarItem) -> MenuProbe {
        var hasMenu = false
        if let el = item.axElement {
            AXUIElementSetMessagingTimeout(el, 0.3)
            var ch: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ch) == .success,
               let kids = ch as? [AnyObject] {
                for k in kids {
                    guard let e = axElement(from: k) else { continue }
                    var role: CFTypeRef?
                    if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success,
                       (role as? String) == (kAXMenuRole as String) { hasMenu = true }
                }
            }
        }
        let app = AXUIElementCreateApplication(item.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var wins: CFTypeRef?
        var count = 0
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success {
            count = (wins as? [AnyObject])?.count ?? 0
        }
        return MenuProbe(hasMenu: hasMenu, windowCount: count)
    }

    public func pressEscape() { DragMover.postEscape() }

    public func readOrderStore() throws -> [String: Double] { try MenuBarOrderStore().readPositions() }

    public func writeOrderStore(_ updates: [String: Double], allowModules: Bool) throws {
        var s = MenuBarOrderStore()
        try s.setPositions(updates, allowModules: allowModules)
    }

    public func waitForOrderStoreQuiet() async {
        let url = MenuBarOrderStore.defaultURL
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            guard let m else { return }
            let age = Date().timeIntervalSince(m)
            if age >= 1.0 { return }
            try? await Task.sleep(for: .seconds(1.0 - age + 0.05))
        }
    }

    public func writeAllowed(_ changes: [String: Bool]) throws {
        var s = ControlCenterTrackedAppsStore()
        try s.setAllowedBatch(changes)
    }

    public var liveHideShowAvailable: Bool { AppGroupEntitlement.hasControlCenterGroup() }

    public func setAllowedLive(_ changes: [String: Bool]) throws {
        guard liveHideShowAvailable else { throw PreferenceWriterError.writeFailed("no app-group entitlement for live writes") }
        var s = ControlCenterTrackedAppsStore()
        try s.setAllowedBatchLive(changes)
    }

    public func readAllowed(_ keys: [String]) throws -> [String: Bool] {
        let entries = try ControlCenterTrackedAppsStore().entries()
        var out: [String: Bool] = [:]
        for k in keys { if let e = entries.first(where: { $0.key == k }) { out[k] = e.isAllowed } }
        return out
    }

    public func restartAgent(timeout: TimeInterval, expectedChange: Int) async -> AgentRestartOutcome {
        await onWork {
            let r = MenuBarAgentControl.restart(timeout: timeout, expectedChange: expectedChange)
            return AgentRestartOutcome(recovered: r.recovered, elapsedMS: r.elapsedMS)
        }
    }

    public func sleep(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }
    public func now() -> Date { Date() }

    public func recordAssumedHidden(_ owners: [AssumedHiddenOwner], hostedAfter: Int?) {
        for o in owners {
            scanner.recordAssumedHidden(pid: o.pid, bundleID: o.bundleID, trackedKey: o.trackedKey, items: o.items, hostedAfter: hostedAfter)
        }
    }

    public func clearAssumedHidden(pids: Set<pid_t>) { scanner.clearAssumedHidden(pids: pids) }

    public func recentCompleteHostedLayout(maxAge: TimeInterval) -> [HostedEntry]? { scanner.recentCompleteHostedLayout(maxAge: maxAge) }

    /// One bounded (2.5 s wall clock) complete read of the agent's hosted tree: strip elements, nil when incomplete.
    private func hostedTreeRead() async -> [AXElementInfo]? {
        // Bounded by wall clock: an AX read can stall while the agent is re-registering scenes right after a hide/show.
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var done = false
            func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        return await withCheckedContinuation { c in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let src = LiveAccessibilitySource()
                var out: [AXElementInfo]?
                if let agent = src.runningApps().first(where: { $0.bundleID == menuBarAgentBundleID }) {
                    let tree = src.agentHostedTree(for: agent, retry: true)
                    if tree.failedReads == 0, tree.unnamedTimeouts == 0, !tree.elements.isEmpty {
                        var uniq: [AXElementInfo] = []
                        for e in tree.elements where !e.stale && e.frame.width > 1 && e.frame.midY < 30
                            && !uniq.contains(where: { $0.frame == e.frame && $0.identifier == e.identifier && $0.axDescription == e.axDescription && $0.title == e.title }) {
                            uniq.append(e)
                        }
                        out = uniq
                    }
                }
                if once.take() { c.resume(returning: out) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { if once.take() { c.resume(returning: nil) } }
        }
    }

    public func hostedBarCount() async -> Int? { await hostedTreeRead()?.count }

    public func hostedLayout() async -> [HostedEntry]? {
        await hostedTreeRead()?.map { HostedEntry(sig: $0.identifier.isEmpty ? $0.axDescription : $0.identifier, minX: $0.frame.minX, width: $0.frame.width) }
    }
}
