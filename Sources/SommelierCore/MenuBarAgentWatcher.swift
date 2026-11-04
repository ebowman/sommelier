import AppKit
import Foundation

/// Pid of the running MenuBarAgent, nil when none.
public func currentMenuBarAgentPID() -> pid_t? {
    NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentBundleID)
        .first { !$0.isTerminated }?.processIdentifier
}

/// Detects a MenuBarAgent respawn (pid change) from NSWorkspace launch/terminate notifications for
/// `com.apple.MenuBarAgent` plus a 2 s pid poll (live: the agent's own launch notification did not arrive,
/// so the poll is the real detector; with 5 s the layout was back 8.7 s after the respawn, too close to the 10 s goal), and reports it once per change (gdu.21).
///
/// A respawn invalidates every AX element and re-bases `TrailingItemPreferredPositions`; its first scans are empty or
/// incomplete for ~2 s. The handler is expected to invalidate scanner caches and call `LayoutEngine.agentRestarted`.
/// Absence of the agent (between terminate and launch) is not a change; the next pid is compared with the last known one.
@MainActor
public final class MenuBarAgentWatcher {
    private let currentPID: @Sendable () -> pid_t?
    private let onChange: (pid_t, pid_t) async -> Void
    private let log: @Sendable (String) -> Void
    private let pollInterval: TimeInterval
    private let busy: @Sendable () -> Bool
    private let isExpected: @Sendable (pid_t) -> Bool
    private var lastPID: pid_t?
    private var tokens: [any NSObjectProtocol] = []
    private var timer: Timer?

    public static let livePID: @Sendable () -> pid_t? = currentMenuBarAgentPID

    public init(pollInterval: TimeInterval = 2, currentPID: @escaping @Sendable () -> pid_t? = MenuBarAgentWatcher.livePID,
                log: @escaping @Sendable (String) -> Void = { _ in },
                busy: @escaping @Sendable () -> Bool = { false }, isExpected: @escaping @Sendable (pid_t) -> Bool = { _ in false},
                onChange: @escaping (pid_t, pid_t) async -> Void) {
        self.pollInterval = pollInterval; self.busy = busy; self.isExpected = isExpected; self.currentPID = currentPID; self.log = log; self.onChange = onChange
    }

    public var knownPID: pid_t? { lastPID }

    public func start() {
        guard tokens.isEmpty else { return }
        // The last KNOWN pid is kept across stop()/start() (pause, permission loss): a respawn meanwhile is reported on resume.
        if lastPID == nil { lastPID = currentPID() }
        log("agent watcher: MenuBarAgent pid \(lastPID.map(String.init) ?? "none")")
        Task { @MainActor [weak self] in await self?.check() }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == menuBarAgentBundleID else { return }
                Task { @MainActor in await self?.check() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for t in tokens { nc.removeObserver(t) }
        tokens = []
        timer?.invalidate(); timer = nil
    }

    /// Compares the current pid with the last known one; on a change logs `agent restarted: pid A -> B` and calls the handler.
    @discardableResult
    public func check() async -> Bool {
        guard let now = currentPID() else { return false }
        // Our own fallback respawn is in progress: report nothing and invalidate nothing mid-action; the pid is absorbed afterwards.
        if busy() { return false }
        guard let old = lastPID, old != now else { lastPID = now; return false }
        if isExpected(now) {
            lastPID = now
            log("agent restarted by Sommelier (expected): pid \(old) -> \(now)")
            return false
        }
        log("agent restarted: pid \(old) -> \(now)")
        lastPID = now   // before the (suspending) handler, so a concurrent check does not report the same change twice
        await onChange(old, now)
        return true
    }
}
