import AppKit
import ServiceManagement

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = "Could not change Start at login"
            a.informativeText = "\(error.localizedDescription)"
            a.runModal()
        }
        NSLog("[Sommelier] login item set(\(on)) status=\(SMAppService.mainApp.status.rawValue)")
    }
}
