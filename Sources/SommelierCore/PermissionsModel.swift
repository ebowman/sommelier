import AppKit
import Foundation
import Observation

@MainActor @Observable
public final class PermissionsModel {
    public private(set) var accessibility: PermissionState = .unknown
    public private(set) var screenRecording: PermissionState = .unknown
    @ObservationIgnored public let checker: any PermissionChecker
    @ObservationIgnored public var onAccessibilityGranted: (() -> Void)?
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

    private func apply(ax: PermissionState) {
        let previous = accessibility
        accessibility = ax
        screenRecording = checker.screenRecording()
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
