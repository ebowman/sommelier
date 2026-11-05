import AppKit
import SommelierCore
import SwiftUI

struct OnboardingView: View {
    let model: PermissionsModel
    /// True in the standalone onboarding window (heading + fixed size); false when embedded in the Settings tab.
    var standalone = false

    var body: some View {
        if standalone {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sommelier needs permission").font(.title2).bold()
                    .padding(.horizontal, 20).padding(.top, 16)
                form
            }
            .frame(width: 540, height: 560)
        } else {
            form.frame(minWidth: 460)
        }
    }

    private var form: some View {
        Form {
            row(title: "Accessibility (required)", state: model.accessibility, optional: false,
                text: "Required to read and arrange menu bar items.",
                request: { model.requestAccessibility() }, pane: .accessibility)
            row(title: "Screen Recording (optional)", state: model.screenRecording, optional: true,
                text: "Optional: enables live images in the overflow panel.",
                request: { model.requestScreenRecording() }, pane: .screenRecording)
            controlCenterRow
            Section {
            } footer: {
                Text("Rebuilding from source changes the app's signature, so macOS asks for Accessibility again; the notarized release keeps its grant across updates signed with the same Developer ID.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// gdu.87: macOS can deny this app Control Center's hidden-item list ("access data from other apps"). Without it Sommelier cannot tell
    /// hidden items from visible ones and does not act. Never claims the app is working.
    private var controlCenterRow: some View {
        let s = model.controlCenterData
        return Section {
            LabeledContent("Control Center data (required)") {
                HStack(spacing: 6) {
                    Circle().fill(s == .granted ? Color.green : (s == .denied ? Color.red : Color.gray)).frame(width: 10, height: 10)
                    Text(s == .granted ? "Readable" : (s == .denied ? "Access denied" : "Unknown"))
                }
            }
            Text(Self.controlCenterText(s)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Request…") { model.requestControlCenterData() }
                Button("Open System Settings") { model.openSettings(.controlCenterData) }
            }
        }
    }

    static func controlCenterText(_ s: PermissionState) -> String {
        switch s {
        case .granted:
            return "Sommelier can read which menu bar items Control Center hides."
        case .unknown:
            return "Control Center has not written its hidden-item list yet; there is nothing to grant. This status updates by itself."
        case .denied:
            return "macOS is denying Sommelier access to Control Center's hidden-item list, so Sommelier cannot tell hidden items from visible ones and will not move or hide anything. "
                + "\"Request…\" asks macOS to show its \"access data from other apps\" prompt, but macOS often does not show it. If Sommelier is listed under Privacy & Security, "
                + "allow it there (Full Disk Access also covers it). Otherwise quit Sommelier, run `tccutil reset SystemPolicyAppData ie.boboco.sommelier` in Terminal and relaunch it. "
                + "This status updates by itself once access works."
        }
    }

    @ViewBuilder
    private func row(title: String, state: PermissionState, optional: Bool, text: String,
                     request: @escaping () -> Void, pane: PermissionPane) -> some View {
        Section {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Circle().fill(color(state, optional: optional)).frame(width: 10, height: 10)
                    Text(label(state, optional: optional))
                }
            }
            Text(text).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Request…", action: request)
                Button("Open System Settings") { model.openSettings(pane) }
            }
        }
    }

    private func color(_ s: PermissionState, optional: Bool) -> Color {
        s == .granted ? .green : (optional ? .gray : .red)
    }

    private func label(_ s: PermissionState, optional: Bool) -> String {
        s == .granted ? "Granted" : (optional ? "Not granted (optional)" : "Not granted")
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(model: PermissionsModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model, standalone: true)))
        window.title = "Sommelier Permissions"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
