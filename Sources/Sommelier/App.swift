import SwiftUI
import ServiceManagement
import AppKit
import SommelierCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionsModel(checker: LivePermissionChecker())
    private(set) lazy var model = AppModel(permissions: permissions)
    private(set) lazy var onboarding = OnboardingWindowController(model: permissions)
    private(set) lazy var settings = SettingsWindowController(model: model)
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let env = ProcessInfo.processInfo.environment
        permissions.refresh()
        permissions.startPolling()
        NSLog("[Sommelier] launch trusted=\(permissions.isReady)")
        model.showOnboarding = { [weak self] in self?.onboarding.show() }
        let sc = StatusItemController(model: model, onSettings: { [weak self] in self?.settings.show() },
                                      onPermissions: { [weak self] in self?.onboarding.show() })
        statusController = sc
        if env["SOMMELIER_SHOW_ONBOARDING"] == "1" { onboarding.show() }
        if env["SOMMELIER_DEBUG_MENU"] == "1" {
            NSLog("[Sommelier] menu titles: %@", sc.buildMenu().items.map { $0.isSeparatorItem ? "---" : "\($0.title)[\($0.state == .on ? "x" : " ")]" }.joined(separator: " | "))
        }
        if env["SOMMELIER_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { sc.openPanelForVerification() }
        }
        if env["SOMMELIER_OPEN_SETTINGS"] == "1" { settings.show() }
        if env["SOMMELIER_TOGGLE_LOGIN"] == "1" {
            NSLog("[Sommelier] login status before=\(SMAppService.mainApp.status.rawValue)")
            LoginItem.set(!LoginItem.isEnabled)
        }
        if env["SOMMELIER_LOGIN_OFF"] == "1" {
            NSLog("[Sommelier] login status before=\(SMAppService.mainApp.status.rawValue)")
            LoginItem.set(false)
        }
        Task { await model.startIfReady() }
    }
}

@main
struct SommelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
