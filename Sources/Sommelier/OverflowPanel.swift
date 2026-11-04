import AppKit
import SwiftUI
import SommelierCore

/// Non-activating panel under the menu bar listing the hidden items. Never activates the app.
final class OverflowNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class OverflowPanelController {
    private let state: EngineState
    private var panel: OverflowNSPanel?
    private var hosting: NSHostingView<OverflowBarView>?
    private let probe = NSHostingView(rootView: OverflowBarView(state: EngineState(), size: nil))
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var anchor: CGRect = .zero
    private var screen: NSScreen?
    private var lastActive = Date()
    private var outsideSince: Date?

    init(state: EngineState) {
        self.state = state
        probe.rootView = OverflowBarView(state: state, size: nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    var entries: [OverflowEntry] { OverflowEntries.make(layout: state.layout, items: state.items) }

    func toggle(anchoredTo itemFrame: CGRect, on screen: NSScreen) {
        if isVisible { hide() } else { show(anchoredTo: itemFrame, on: screen) }
    }

    func show(anchoredTo itemFrame: CGRect, on screen: NSScreen) {
        self.anchor = itemFrame
        self.screen = screen
        NSLog("[Sommelier] before show: NSApp.isActive=%d", NSApp.isActive)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place()
        panel.makeKeyAndOrderFront(nil)   // non-activating: becomes key without activating the app
        NSLog("[Sommelier] panel shown; NSApp.isActive=%d key=%d", NSApp.isActive, panel.isKeyWindow)
        lastActive = Date(); outsideSince = nil
        installMonitors()
    }

    func hide(_ reason: String = "requested") {
        if isVisible { NSLog("[Sommelier] overflow hide: %@", reason) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil; localMonitor = nil
        timer?.invalidate(); timer = nil
        if let p = panel, p.isKeyWindow { p.resignKey() }
        panel?.orderOut(nil)
    }

    // MARK: layout

    private func barHeight(_ s: NSScreen) -> CGFloat {
        max(NSStatusBar.system.thickness, s.frame.maxY - s.visibleFrame.maxY)
    }

    private func menuBarStrip(_ s: NSScreen) -> CGRect {
        let h = barHeight(s)
        return CGRect(x: s.frame.minX, y: s.frame.maxY - h, width: s.frame.width, height: h)
    }

    private func place() {
        guard let panel, let hosting, let screen else { return }
        let vis = screen.visibleFrame
        let ideal = probe.fittingSize
        let cap = OverflowPlacement.maxWidth(anchor: anchor, screenVisible: vis)
        let size = CGSize(width: max(ideal.width, 60), height: max(ideal.height, 30))
        let barBottom = screen.frame.maxY - barHeight(screen)
        let f = OverflowPlacement.panelFrame(anchor: anchor, menuBarBottomY: barBottom, screenVisible: vis, contentSize: size)
        if lastLogged != f {
            lastLogged = f
            NSLog("[Sommelier] panel place: ideal=%@ cap=%.0f final=%@", NSStringFromSize(ideal), cap, NSStringFromRect(f))
        }
        hosting.rootView = OverflowBarView(state: state, size: f.size)
        if panel.frame != f { panel.setFrame(f, display: true) }
        hosting.frame = panel.contentView?.bounds ?? .zero
    }

    private var lastLogged: CGRect = .zero

    private func makePanel() -> OverflowNSPanel {
        let p = OverflowNSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 44),
                                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                backing: .buffered, defer: true)
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.onEscape = { [weak self] in self?.hide("escape") }
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: OverflowBarView(state: state, size: nil))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = effect.bounds
        effect.addSubview(host)
        p.contentView = effect
        hosting = host
        return p
    }

    // MARK: close rules

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] ev in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if ev.type == .keyDown {   // delivered when another app owns the keyboard (needs Accessibility trust)
                    if ev.keyCode == 53 { self.hide("escape (global)") }
                    return
                }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.hide("click outside") }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            if ev.keyCode == 53 {   // Escape
                MainActor.assumeIsolated { self?.hide("escape") }
                return nil
            }
            return ev
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let panel, panel.isVisible, let screen else { return }
        place()
        let p = NSEvent.mouseLocation
        let inside = panel.frame.contains(p) || menuBarStrip(screen).contains(p)
        let now = Date()
        if inside {
            outsideSince = nil
            if panel.frame.contains(p) || NSEvent.pressedMouseButtons != 0 || p != lastPointer { lastActive = now }
            lastPointer = p
        } else {
            if outsideSince == nil { outsideSince = now }
            if now.timeIntervalSince(outsideSince!) >= 0.4 { hide("pointer left panel+bar at \(NSStringFromPoint(p))"); return }
        }
        let secs = UserDefaults.standard.object(forKey: "autoRehideSeconds") as? Int ?? 10
        if secs > 0, now.timeIntervalSince(lastActive) >= Double(secs) { hide("inactivity") }
    }

    private var lastPointer: CGPoint = .zero
}

struct OverflowBarView: View {
    let state: EngineState
    /// nil = measure the ideal (uncapped) size; otherwise the final panel size (content scrolls horizontally).
    let size: CGSize?
    @AppStorage("overflowShowNames") private var showNames = true

    var body: some View {
        let entries = OverflowEntries.make(layout: state.layout, items: state.items)
        Group {
            if entries.isEmpty {
                HStack(spacing: 10) {
                    Text("Nothing hidden").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Arrange…") {}.disabled(true)   // gdu.19
                }
                .padding(8)
            } else if let size {
                ScrollView(.horizontal, showsIndicators: false) { row(entries) }
                    .frame(width: max(0, size.width - 16), height: max(0, size.height - 16))
                    .padding(8)
            } else {
                row(entries).padding(8)
            }
        }
        .fixedSize()
    }

    private func row(_ entries: [OverflowEntry]) -> some View {
        HStack(spacing: 6) {
            ForEach(entries, id: \.key) { e in
                OverflowEntryView(entry: e, showName: showNames)
            }
        }
    }
}

struct OverflowEntryView: View {
    let entry: OverflowEntry
    let showName: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            icon.frame(width: 18, height: 18)
            if showName { Text(entry.displayName).font(.system(size: 12)).lineLimit(1) }
        }
        .frame(minWidth: entry.width)
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSLog("[Sommelier] overflow click %@", "\(entry.key)") }
        .help(entry.displayName)
    }

    @ViewBuilder private var icon: some View {
        if let img = appIcon() { Image(nsImage: img).resizable().interpolation(.high) }
        else { Image(systemName: "menubar.rectangle").resizable().scaledToFit() }
    }

    private func appIcon() -> NSImage? {
        let ws = NSWorkspace.shared
        if let path = NSRunningApplication(processIdentifier: entry.ownerPID)?.bundleURL?.path {
            return ws.icon(forFile: path)
        }
        if let id = entry.ownerBundleID, let url = ws.urlForApplication(withBundleIdentifier: id) {
            return ws.icon(forFile: url.path)
        }
        return nil
    }
}
