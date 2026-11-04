import SwiftUI
import AppKit
import ServiceManagement
import SommelierCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("autoRehideSeconds") private var autoRehide = 10
    @AppStorage("revealMode") private var revealMode = "panel"
    @AppStorage("overflowShowNames") private var showNames = true
    @State private var login = LoginItem.isEnabled

    var body: some View {
        TabView {
            Form {
                Toggle("Start at login", isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.isEnabled }))
                Picker("New items", selection: $model.newItemPolicy) {
                    Text("Visible at end").tag(NewItemPolicy.visibleAtEnd)
                    Text("Hidden").tag(NewItemPolicy.hidden)
                }
                Picker("Reveal mode", selection: $revealMode) {
                    Text("Panel below menu bar").tag("panel")
                    Text("Inline").tag("inline")
                }
                Toggle("Show names in panel", isOn: $showNames)
                Stepper("Auto re-hide after \(autoRehide == 0 ? "never" : "\(autoRehide) s")", value: $autoRehide, in: 0...60)
            }
            .padding()
            .tabItem { Text("General") }

            OnboardingView(model: model.permissions)
                .tabItem { Text("Permissions") }

            Text("Coming soon (gdu.20)")
                .padding()
                .tabItem { Text("Spacing") }
        }
        .frame(width: 480, height: 320)
        .onAppear { login = LoginItem.isEnabled }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = "Sommelier Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
