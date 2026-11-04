import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionState: Equatable, Sendable { case granted, denied, unknown }

public enum PermissionPane: Sendable { case accessibility, screenRecording }

public protocol PermissionChecker: Sendable {
    /// `prompt: true` may show the system prompt; call it only from a user action, never from polling.
    func accessibility(prompt: Bool) -> PermissionState
    func screenRecording() -> PermissionState
    func requestScreenRecording()
    func openSettings(_ pane: PermissionPane)
}

public enum PermissionTransitions {
    /// True when moving from `previous` to `current` is a transition into granted.
    public static func shouldFireGranted(previous: PermissionState, current: PermissionState) -> Bool {
        current == .granted && previous != .granted
    }
}

public struct LivePermissionChecker: PermissionChecker {
    public init() {}

    public static func settingsURL(for pane: PermissionPane) -> URL {
        switch pane {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    public func accessibility(prompt: Bool) -> PermissionState {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary  // == kAXTrustedCheckOptionPrompt
        return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
    }

    public func screenRecording() -> PermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    public func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    public func openSettings(_ pane: PermissionPane) {
        NSWorkspace.shared.open(Self.settingsURL(for: pane))
    }
}

/// Test double: states can be flipped; records calls.
public final class FakePermissionChecker: PermissionChecker, @unchecked Sendable {
    private let lock = NSLock()
    private var ax: PermissionState
    private var sr: PermissionState
    private var _promptCalls = 0
    private var _opened: [PermissionPane] = []
    private var _srRequests = 0

    public init(accessibility: PermissionState = .denied, screenRecording: PermissionState = .denied) {
        ax = accessibility; sr = screenRecording
    }

    public func setAccessibility(_ s: PermissionState) { lock.withLock { ax = s } }
    public func setScreenRecording(_ s: PermissionState) { lock.withLock { sr = s } }
    public var promptCalls: Int { lock.withLock { _promptCalls } }
    public var openedPanes: [PermissionPane] { lock.withLock { _opened } }
    public var screenRecordingRequests: Int { lock.withLock { _srRequests } }

    public func accessibility(prompt: Bool) -> PermissionState {
        lock.withLock { if prompt { _promptCalls += 1 }; return ax }
    }
    public func screenRecording() -> PermissionState { lock.withLock { sr } }
    public func requestScreenRecording() { lock.withLock { _srRequests += 1 } }
    public func openSettings(_ pane: PermissionPane) { lock.withLock { _opened.append(pane) } }
}
