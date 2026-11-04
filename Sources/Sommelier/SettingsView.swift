import SwiftUI
import AppKit
import ServiceManagement
import SommelierCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("autoRehideSeconds") private var autoRehide = 10
    @AppStorage("revealMode") private var revealMode = "panel"
    @AppStorage("overflowShowNames") private var showNames = true
    /// Last-resort MenuBarAgent restart (gdu.55): ON by default only when the app has no live hide/show entitlement.
    @AppStorage("allowAgentRestart") private var allowAgentRestart = !AppGroupEntitlement.hasControlCenterGroup()
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
                Toggle("Allow menu bar restart as a last resort", isOn: $allowAgentRestart)
                    .help("If hiding or showing an item cannot be written to Control Center, restarting the menu bar (a brief blank bar) is the only fallback. Off: the item is reported as failed instead.")
                Stepper("Auto re-hide after \(autoRehide == 0 ? "never" : "\(autoRehide) s")", value: $autoRehide, in: 0...60)
            }
            .padding()
            .tabItem { Text("General") }

            OnboardingView(model: model.permissions)
                .tabItem { Text("Permissions") }

            SpacingTab()
                .tabItem { Text("Spacing") }
        }
        .frame(width: 480, height: 320)
        .onAppear { login = LoginItem.isEnabled }
    }
}

/// Spacing tab (gdu.20). Writes on slider release only; never restarts the menu bar (gdu.55).
struct SpacingTab: View {
    static let statusText = "Each app picks up a change when it is relaunched; apps that are already running keep their old spacing. Nothing restarts the menu bar for you. Padding only changes the highlight around an item."
    private let settings = SpacingSettings()
    @State private var spacing: Double = 8
    @State private var padding: Double = 8
    @State private var spacingSet = false
    @State private var paddingSet = false

    var body: some View {
        Form {
            row("Item spacing", value: $spacing, isSet: spacingSet) { settings.set(spacing: $0); reload() }
            row("Selection padding", value: $padding, isSet: paddingSet) { settings.set(padding: $0); reload() }
            Button("Reset to system default") { settings.reset(); reload() }
            Text(Self.statusText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .onAppear { reload() }
    }

    private func row(_ title: String, value: Binding<Double>, isSet: Bool, commit: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: 0...24, step: 1) { editing in
                if !editing { commit(Int(value.wrappedValue)) }
            }
            TextField("", value: Binding(get: { Int(value.wrappedValue) }, set: { value.wrappedValue = Double(SpacingSettings.clamp($0)) }),
                      format: .number)
                .frame(width: 44)
                .onSubmit { commit(Int(value.wrappedValue)) }
            Text(isSet ? "set" : "default").font(.caption).foregroundStyle(.secondary).frame(width: 48)
        }
    }

    private func reload() {
        let c = settings.current()
        spacingSet = c.spacing != nil; paddingSet = c.padding != nil
        spacing = Double(c.spacing ?? 8); padding = Double(c.padding ?? 8)
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
