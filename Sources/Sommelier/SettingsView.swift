import SwiftUI
import AppKit
import ServiceManagement
import SommelierCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("autoRehideSeconds") private var autoRehide = 10
    @AppStorage("showMouseControlNotice") private var showMouseNotice = true
    @AppStorage("revealMode") private var revealMode = "panel"
    @AppStorage("overflowShowNames") private var showNames = true
    /// Last-resort MenuBarAgent restart (gdu.55): ON by default only when the app has no live hide/show entitlement.
    @AppStorage("allowAgentRestart") private var allowAgentRestart = !AppGroupEntitlement.hasControlCenterGroup()
    @State private var login = LoginItem.isEnabled

    private enum Tab: Hashable { case general, permissions, spacing }
    @State private var tab: Tab = .general

    /// Width shared by all tabs; heights are per tab so the window fits each pane's content (no dead bands).
    private static let width: CGFloat = 540
    private var height: CGFloat {
        switch tab {
        case .general: return 400
        case .permissions: return 384
        case .spacing: return 278
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section {
                    // ejb.30: the switch itself is the one thing observe-only writes (the app's own preference). The other @AppStorage controls below
                    // only change the app's own preferences too, which observe-only does not forbid; what it forbids is changing the bar, Control
                    // Center, system preferences, the login item and Sommelier's layout files.
                    Toggle(ObserveOnly.settingTitle, isOn: Binding(get: { model.observeOnly }, set: { on in
                        if on { model.setObserveOnly(true) } else { model.armWithConfirmation() }
                    }))
                    .disabled(model.observeGate.forcedByEnv)
                    if model.observeGate.forcedByEnv {
                        Text(ObserveOnly.forcedNote).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Start at login", isOn: Binding(get: { login }, set: { LoginItem.set($0); login = LoginItem.isEnabled }))
                    Picker("New items", selection: $model.newItemPolicy) {
                        Text("Visible at end").tag(NewItemPolicy.visibleAtEnd)
                        Text("Hidden").tag(NewItemPolicy.hidden)
                    }
                    Picker("Left click", selection: $revealMode) {
                        Text("Overflow panel (default)").tag("panel")
                        Text("Show hidden items in the menu bar").tag("inline")
                    }
                    Toggle("Show names in panel", isOn: $showNames)
                    Toggle("Show a notice while Sommelier moves the mouse", isOn: $showMouseNotice)
                        .help("Reordering menu bar items drags the real pointer for a few seconds; this floating notice says so. Hiding and showing items does not move the mouse.")
                    Stepper("Auto re-hide after \(autoRehide == 0 ? "never" : "\(autoRehide) s")", value: $autoRehide, in: 0...60)
                }
                Section {
                    Toggle("Allow menu bar restart as a last resort", isOn: $allowAgentRestart)
                        .help("If hiding or showing an item cannot be written to Control Center, restarting the menu bar (a brief blank bar) is the only fallback. Off: the item is reported as failed instead.")
                } footer: {
                    Text("If hiding or showing an item cannot be written to Control Center, restarting the menu bar (a brief blank bar) is the only fallback. Off: the item is reported as failed instead.")
                }
            }
            .formStyle(.grouped)
            .tag(Tab.general)
            .tabItem { Text("General") }

            OnboardingView(model: model.permissions)
                .tag(Tab.permissions)
                .tabItem { Text("Permissions") }

            SpacingTab(observeGate: model.observeGate)
                .tag(Tab.spacing)
                .tabItem { Text("Spacing") }
        }
        .frame(width: Self.width, height: height)
        .onAppear { login = LoginItem.isEnabled }
    }
}

/// Spacing tab (gdu.20, layout gdu.59). Slider writes on release, field on Return and focus loss; never restarts the menu bar (gdu.55).
struct SpacingTab: View {
    static let statusText = "Each app picks up a change when it relaunches; running apps keep their old spacing. Nothing restarts the menu bar."
    private let settings = SpacingSettings()
    /// ejb.30: observe-only writes no global spacing preference (read live).
    let observeGate: ObserveOnlyGate
    @State private var spacing: Int?
    @State private var padding: Int?

    private static let fallback = 8

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SpacingRow(title: "Item spacing", caption: "Gap between items", value: $spacing, fallback: Self.fallback) {
                        if blockedByObserveOnly("spacing \($0)") { return }
                        settings.set(spacing: $0); reload()
                    }
                    SpacingRow(title: "Selection padding", caption: "Highlight padding around a clicked item", value: $padding, fallback: Self.fallback) {
                        if blockedByObserveOnly("padding \($0)") { return }
                        settings.set(padding: $0); reload()
                    }
                } footer: {
                    Text(Self.statusText).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Reset to system default") { if blockedByObserveOnly("reset spacing") { return }; settings.reset(); reload() }
                    .disabled(spacing == nil && padding == nil)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear { reload() }
    }

    private func blockedByObserveOnly(_ what: String) -> Bool {
        guard observeGate.isOn else { return false }
        AppLog.log(.app, "observe-only: would set \(what)")
        reload()
        return true
    }

    private func reload() {
        let c = settings.current()
        spacing = c.spacing; padding = c.padding
    }
}

/// One labelled setting: slider + numeric field + "pt" + stepper on one line, caption underneath.
private struct SpacingRow: View {
    let title: String
    let caption: String
    @Binding var value: Int?
    let fallback: Int
    let commit: (Int) -> Void
    @State private var text = ""
    @State private var dragValue: Double = 8
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Slider(value: $dragValue, in: 0...24) { editing in
                        if !editing { apply(Int(dragValue.rounded())) }
                    }
                    .frame(width: 150)
                    TextField("", text: $text, prompt: Text("Default"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .focused($focused)
                        .onSubmit { applyText() }
                        .onChange(of: focused) { _, now in if !now { applyText() } }
                    Text("pt").foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { value ?? fallback }, set: { apply($0) }),
                            in: SpacingSettings.range)
                        .labelsHidden()
                }
            }
            Text(value == nil ? "\(caption) \u{00B7} 0\u{2013}24 pt \u{00B7} System default" : "\(caption) \u{00B7} 0\u{2013}24 pt")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { sync() }
        .onChange(of: value) { _, _ in sync() }
    }

    private func sync() {
        text = value.map(String.init) ?? ""
        dragValue = Double(value ?? fallback)
    }

    private func apply(_ v: Int) {
        let c = SpacingSettings.clamp(v)
        text = String(c); dragValue = Double(c)
        commit(c)
    }

    private func applyText() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { sync(); return }
        guard let n = Int(t) else { sync(); return }
        if n != value || n != SpacingSettings.clamp(n) { apply(n) } else { sync() }
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
