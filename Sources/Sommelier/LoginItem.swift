import AppKit
import ServiceManagement
import SommelierCore

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// ejb.30: set by `AppModel` at launch; read live (observe-only registers no login item).
    static var observeGate = ObserveOnlyGate(fixed: false)

    static func set(_ on: Bool) {
        if observeGate.isOn { AppLog.log(.app, "observe-only: would set login item \(on)"); return }   // ejb.30
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change Start at login"
            a.informativeText = "\(error.localizedDescription)"
            a.runModal()
        }
        AppLog.log(.app, "login item set(\(on)) status=\(SMAppService.mainApp.status.rawValue)")
    }
}
