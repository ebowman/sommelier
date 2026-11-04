import SwiftUI
import AppKit
import SommelierCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionsModel(checker: LivePermissionChecker())
    private(set) lazy var onboarding = OnboardingWindowController(model: permissions)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        permissions.onAccessibilityGranted = {
            NSLog("accessibility granted")
            // gdu.14: start engine here
        }
        permissions.refresh()
        permissions.startPolling()
        if !permissions.isReady || ProcessInfo.processInfo.environment["SOMMELIER_SHOW_ONBOARDING"] == "1" {
            onboarding.show()
        }
    }
}

@main
struct SommelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Sommelier", systemImage: "wineglass") {
            MenuContent(delegate: delegate)
        }
    }
}

struct MenuContent: View {
    let delegate: AppDelegate

    var body: some View {
        Button(delegate.permissions.isReady ? "Permissions…" : "Grant Accessibility…") {
            delegate.onboarding.show()
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
