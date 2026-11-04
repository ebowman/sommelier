import SwiftUI
import ServiceManagement
import AppKit
import SommelierCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions = PermissionsModel(checker: LivePermissionChecker())
    private(set) lazy var model = AppModel(permissions: permissions)
    private(set) lazy var onboarding = OnboardingWindowController(model: permissions)
    private(set) lazy var arrange = ArrangeWindowController(model: model)
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
                                      onArrange: { [weak self] in self?.arrange.show() },
                                      onPermissions: { [weak self] in self?.onboarding.show() })
        statusController = sc
        if env["SOMMELIER_SHOW_ONBOARDING"] == "1" { onboarding.show() }
        if env["SOMMELIER_DEBUG_MENU"] == "1" {
            NSLog("[Sommelier] menu titles: %@", sc.buildMenu().items.map { $0.isSeparatorItem ? "---" : "\($0.title)[\($0.state == .on ? "x" : " ")]" }.joined(separator: " | "))
        }
        if env["SOMMELIER_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { sc.openPanelForVerification() }
        }
        if let spec = env["SOMMELIER_ACTIVATE"], !spec.isEmpty {
            let right = spec.hasSuffix("|right")
            let keyText = right ? String(spec.dropLast("|right".count)) : spec
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(3))
                guard let key = ItemKey(storeKey: keyText) else { NSLog("[Sommelier] activate: bad key %@", keyText); return }
                for _ in 0..<40 where model.engine == nil { try? await Task.sleep(for: .milliseconds(250)) }
                let t0 = Date()
                let r = await model.activate(key, button: right ? .right : .left)
                NSLog("[Sommelier] activate result for %@: %@ (total %d ms)", keyText, "\(r)", Int(Date().timeIntervalSince(t0) * 1000))
            }
        }
        if env["SOMMELIER_OPEN_ARRANGE"] == "1" { arrange.show() }
        if let spec = env["SOMMELIER_ARRANGE_MOVE"], !spec.isEmpty {
            arrange.viewModel.runEnvMove(spec, after: .seconds(2))
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
