import Testing
import Foundation
@testable import SommelierCore

@Suite struct PermissionsTests {
    @Test func settingsURLs() {
        #expect(LivePermissionChecker.settingsURL(for: .accessibility).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(LivePermissionChecker.settingsURL(for: .screenRecording).absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test func transitions() {
        #expect(PermissionTransitions.shouldFireGranted(previous: .unknown, current: .granted))
        #expect(PermissionTransitions.shouldFireGranted(previous: .denied, current: .granted))
        #expect(!PermissionTransitions.shouldFireGranted(previous: .granted, current: .granted))
        #expect(!PermissionTransitions.shouldFireGranted(previous: .denied, current: .denied))
        #expect(!PermissionTransitions.shouldFireGranted(previous: .granted, current: .denied))
    }

    @MainActor @Test func modelPollsAndFiresOnce() async throws {
        let fake = FakePermissionChecker()
        let model = PermissionsModel(checker: fake, pollInterval: .milliseconds(10))
        var fired = 0
        model.onAccessibilityGranted = { fired += 1 }
        model.refresh()
        #expect(model.accessibility == .denied)
        #expect(!model.isReady)
        model.startPolling()
        model.startPolling()
        fake.setAccessibility(.granted)
        for _ in 0..<20 where model.accessibility != .granted { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.accessibility == .granted)
        #expect(model.isReady)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fired == 1)
        // granted -> denied -> granted fires again
        fake.setAccessibility(.denied)
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.accessibility == .denied)
        fake.setAccessibility(.granted)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fired == 2)
        model.stopPolling()
        fake.setAccessibility(.denied)
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.accessibility == .granted)  // polling stopped
    }

    @MainActor @Test func promptOnlyOnUserAction() {
        let fake = FakePermissionChecker()
        let model = PermissionsModel(checker: fake)
        model.refresh()
        #expect(fake.promptCalls == 0)
        model.requestAccessibility()
        #expect(fake.promptCalls == 1)
        model.requestScreenRecording()
        #expect(fake.screenRecordingRequests == 1)
        model.openSettings(.screenRecording)
        #expect(fake.openedPanes == [.screenRecording])
    }
}
