import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum PermissionState: Equatable, Sendable { case granted, denied, unknown }

public enum PermissionPane: Sendable { case accessibility, screenRecording, controlCenterData }

public protocol PermissionChecker: Sendable {
    /// `prompt: true` may show the system prompt; call it only from a user action, never from polling.
    func accessibility(prompt: Bool) -> PermissionState
    func screenRecording() -> PermissionState
    func requestScreenRecording()
    func openSettings(_ pane: PermissionPane)
    /// gdu.87: whether this process can read Control Center's tracked-applications store (macOS "access data from other apps").
    /// Cheap and never prompts (no direct read, no CFPreferences): safe for background polling.
    func controlCenterData() -> PermissionState
    /// User action ONLY: a direct main-thread read of the group-container plists, which is what may make macOS show its consent dialog.
    func requestControlCenterData()
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
        case .controlCenterData:
            // There is no "App Data" list in Privacy & Security on macOS 27 (TCCServiceList.plist has Privacy_AppBundles = App Management
            // only, no Privacy_AppData), so open the Privacy & Security root.
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
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

    public func controlCenterData() -> PermissionState { ControlCenterTrackedAppsStore.probeAccess() }
    public func requestControlCenterData() { ControlCenterTrackedAppsStore.requestAccess() }

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
    private var cc: PermissionState = .granted
    private var _ccRequests = 0

    public init(accessibility: PermissionState = .denied, screenRecording: PermissionState = .denied) {
        ax = accessibility; sr = screenRecording
    }

    public func setAccessibility(_ s: PermissionState) { lock.withLock { ax = s } }
    public func setScreenRecording(_ s: PermissionState) { lock.withLock { sr = s } }
    public func setControlCenterData(_ s: PermissionState) { lock.withLock { cc = s } }
    public var controlCenterDataRequests: Int { lock.withLock { _ccRequests } }
    public var promptCalls: Int { lock.withLock { _promptCalls } }
    public var openedPanes: [PermissionPane] { lock.withLock { _opened } }
    public var screenRecordingRequests: Int { lock.withLock { _srRequests } }

    public func accessibility(prompt: Bool) -> PermissionState {
        lock.withLock { if prompt { _promptCalls += 1 }; return ax }
    }
    public func screenRecording() -> PermissionState { lock.withLock { sr } }
    public func requestScreenRecording() { lock.withLock { _srRequests += 1 } }
    public func openSettings(_ pane: PermissionPane) { lock.withLock { _opened.append(pane) } }
    public func controlCenterData() -> PermissionState { lock.withLock { cc } }
    public func requestControlCenterData() { lock.withLock { _ccRequests += 1 } }
}
