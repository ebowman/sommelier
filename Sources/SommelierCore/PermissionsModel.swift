import AppKit
import Foundation
import Observation

@MainActor @Observable
public final class PermissionsModel {
    public private(set) var accessibility: PermissionState = .unknown
    public private(set) var screenRecording: PermissionState = .unknown
    /// gdu.87: can this process read Control Center's hidden-item list? Required for the bar to be shown truthfully, but it does not gate
    /// `isReady` (the engine refuses to act on its own while it is denied, and says why).
    public private(set) var controlCenterData: PermissionState = .unknown
    @ObservationIgnored public let checker: any PermissionChecker
    @ObservationIgnored public var onAccessibilityGranted: (() -> Void)?
    /// gdu.87: fired on a transition into granted for Control Center data (the engine then re-checks at once).
    @ObservationIgnored public var onControlCenterDataGranted: (() -> Void)?
    /// Once granted, the background probe runs at most this often.
    @ObservationIgnored public var grantedProbeInterval: TimeInterval = 30
    @ObservationIgnored private var lastControlCenterProbe: Date?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    public var isReady: Bool { accessibility == .granted }

    public init(checker: any PermissionChecker, pollInterval: Duration = .seconds(2)) {
        self.checker = checker
        self.pollInterval = pollInterval
    }

    /// Cheap and synchronous; never prompts.
    public func refresh() { apply(ax: checker.accessibility(prompt: false)) }

    private func apply(ax: PermissionState, forceControlCenterProbe: Bool = false) {
        let previous = accessibility
        accessibility = ax
        screenRecording = checker.screenRecording()
        // The Control Center probe never prompts (stat/access only) and is skipped while recently granted.
        let now = Date()
        if forceControlCenterProbe || controlCenterData != .granted || lastControlCenterProbe.map({ now.timeIntervalSince($0) >= grantedProbeInterval }) ?? true {
            lastControlCenterProbe = now
            let before = controlCenterData
            controlCenterData = checker.controlCenterData()
            if controlCenterData == .granted, before != .granted { onControlCenterDataGranted?() }
        }
        if PermissionTransitions.shouldFireGranted(previous: previous, current: ax) {
            onAccessibilityGranted?()
        }
    }

    /// User action: may show the system prompt.
    public func requestAccessibility() { apply(ax: checker.accessibility(prompt: true)) }

    public func requestScreenRecording() {
        checker.requestScreenRecording()
        refresh()
    }

    public func requestControlCenterData() {
        checker.requestControlCenterData()
        apply(ax: checker.accessibility(prompt: false), forceControlCenterProbe: true)
    }

    public func openSettings(_ pane: PermissionPane) { checker.openSettings(pane) }

    public func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        if let o = activationObserver { NotificationCenter.default.removeObserver(o) }
        activationObserver = nil
    }
}
