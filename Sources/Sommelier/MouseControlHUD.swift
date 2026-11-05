import AppKit
import SwiftUI
import SommelierCore

/// Small non-activating HUD shown while the engine drives the real pointer (gdu.103). It never takes key/main status and
/// ignores mouse events.
@MainActor
final class MouseControlHUDController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<MouseControlHUDView>?

    func show(text: String, name: String) {
        let p = panel ?? makePanel()
        hosting?.rootView = MouseControlHUDView(text: text)
        if let hosting { p.setContentSize(hosting.fittingSize) }
        place(p)
        p.orderFrontRegardless()
        AppLog.log(.app, "mouse notice: show \(name)")
    }

    func hide() {
        panel?.orderOut(nil)
        AppLog.log(.app, "mouse notice: hide")
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 48),
                        styleMask: [.nonactivatingPanel, .utilityWindow, .borderless],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        let h = NSHostingView(rootView: MouseControlHUDView(text: ""))
        p.contentView = h
        hosting = h
        panel = p
        return p
    }

    private func place(_ p: NSPanel) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 12))
    }
}

struct MouseControlHUDView: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").font(.system(size: 14))
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
    }
}

/// 250 ms tick (common run loop modes so it fires during drag tracking) feeding `MouseControlNotice` from the engine state.
@MainActor
final class MouseControlNoticeDriver {
    private let state: EngineState
    private let hud = MouseControlHUDController()
    private var notice = MouseControlNotice()
    private var timer: Timer?
    private var currentName = ""

    init(state: EngineState) { self.state = state }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let enabled = UserDefaults.standard.object(forKey: "showMouseControlNotice") as? Bool ?? true
        let items = state.items
        let name: (ItemKey) -> String = { key in
            let n = items[key].map(OverflowEntries.displayName) ?? "\(key)"
            return n
        }
        switch notice.update(inFlight: state.inFlight, enabled: enabled, displayName: name) {
        case .show(let text)?:
            if case .move(let key, _)? = state.inFlight { currentName = name(key) }
            hud.show(text: text, name: currentName)
        case .hide?: hud.hide()
        case nil: break
        }
    }
}
