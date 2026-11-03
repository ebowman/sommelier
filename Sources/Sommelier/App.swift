import SwiftUI
import AppKit
import SommelierCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct SommelierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("Sommelier", systemImage: "wineglass") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
