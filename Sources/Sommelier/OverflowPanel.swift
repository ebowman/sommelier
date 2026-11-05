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

/// Entries whose last activation failed (red outline + tooltip), cleared after a few seconds.
@MainActor @Observable
final class OverflowFeedback {
    var model = OverflowFeedbackModel()
    var errors: [ItemKey: String] { model.errors }
}

@MainActor
final class OverflowPanelController {
    private let state: EngineState
    private let onArrange: () -> Void
    private let onActivate: (ItemKey, ClickButton) async -> ActivationResult
    private let feedback = OverflowFeedback()
    /// One 4 s clear per failed key: a later failure of another key must not cancel this one's.
    private var clearTasks: [ItemKey: Task<Void, Never>] = [:]
    private var panel: OverflowNSPanel?
    private var hosting: NSHostingView<OverflowBarView>?
    private let probe: NSHostingView<OverflowBarView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var anchor: CGRect = .zero
    private var screen: NSScreen?
    private var lastActive = Date()
    private var outsideSince: Date?

    init(state: EngineState, onArrange: @escaping () -> Void = {},
         onActivate: @escaping (ItemKey, ClickButton) async -> ActivationResult = { _, _ in .failed(.unavailable("not wired")) }) {
        self.state = state
        self.onArrange = onArrange
        self.onActivate = onActivate
        probe = NSHostingView(rootView: OverflowBarView(state: state, size: nil, onArrange: onArrange))
        probe.rootView.feedback = feedback
    }

    /// A click on an entry: the panel gets out of the way at once (the item's own menu opens where the item is), the
    /// activator does the rest; a failure brings the panel back with the entry outlined in red.
    private func activate(_ entry: OverflowEntry, _ button: ClickButton) {
        if entry.kind == .notFitting, button == .right { return }
        let (anchor, screen) = (self.anchor, self.screen)
        hide("activate")
        let key = entry.key
        let listAtClick = self.entries
        Task { @MainActor [weak self] in
            guard let self else { return }
            let r = await self.onActivate(key, button)
            guard let caption = ActivationCaption.make(r) else { return }
            if caption.severity == .neutral {
                self.feedback.model.note(key, message: caption.text)
                self.scheduleClear(key)
                return
            }
            NSLog("[Sommelier] overflow activation of %@ failed: %@", "\(key)", caption.text)
            self.feedback.model.fail(entry, message: caption.text, in: listAtClick)
            if let screen { self.show(anchoredTo: anchor, on: screen) }
            self.scheduleClear(key)
        }
    }

    private func scheduleClear(_ key: ItemKey) {
        clearTasks[key]?.cancel()
        clearTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.feedback.model.clear(key)
            self.clearTasks[key] = nil
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    var entries: [OverflowEntry] { feedback.model.rendered(OverflowEntries.make(layout: state.layout, items: state.items, units: state.hideUnits)) }

    func toggle(anchoredTo itemFrame: CGRect, on screen: NSScreen) {
        if isVisible { hide() } else { show(anchoredTo: itemFrame, on: screen) }
    }

    func show(anchoredTo itemFrame: CGRect, on screen: NSScreen) {
        if isVisible {   // already open (e.g. activation failed while the user reopened it): re-place only, keep the one set of monitors
            self.anchor = itemFrame; self.screen = screen
            place()
            return
        }
        self.anchor = itemFrame
        self.screen = screen
        placeCount = 0
        NSLog("[Sommelier] before show: NSApp.isActive=%d", NSApp.isActive)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place()
        panel.makeKeyAndOrderFront(nil)   // non-activating: becomes key without activating the app
        NSLog("[Sommelier] panel shown; NSApp.isActive=%d key=%d", NSApp.isActive, panel.isKeyWindow)
        lastActive = Date(); outsideSince = nil
        installMonitors()
    }

    /// Display configuration changed: re-anchor an open panel to the status item's current frame and screen.
    func reposition(anchoredTo itemFrame: CGRect, on screen: NSScreen) {
        guard isVisible else { return }
        anchor = itemFrame
        self.screen = screen
        place()
        NSLog("[Sommelier] overflow panel repositioned after display change: %@", NSStringFromRect(panel?.frame ?? .zero))
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

    /// What the last `place()` was computed from; `tick()` re-places only when this changes.
    private struct PlaceInput: Equatable {
        var entries: [OverflowEntry]
        var errors: [ItemKey: String]
        var notes: [ItemKey: String]
        var showNames: Bool
        var anchor: CGRect
        var screenFrame: CGRect
        var screenVisible: CGRect
    }
    private var lastPlaced: PlaceInput?
    private var placeCount = 0

    private func placeInput(_ screen: NSScreen) -> PlaceInput {
        PlaceInput(entries: entries, errors: feedback.errors, notes: feedback.model.notes,
                   showNames: UserDefaults.standard.object(forKey: "overflowShowNames") as? Bool ?? true,
                   anchor: anchor, screenFrame: screen.frame, screenVisible: screen.visibleFrame)
    }

    private func place() {
        guard let panel, let hosting, let screen else { return }
        lastPlaced = placeInput(screen)
        placeCount += 1
        NSLog("[Sommelier] place() run #%d", placeCount)
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
        hosting.rootView = OverflowBarView(state: state, size: f.size, onArrange: onArrange, feedback: feedback, onActivate: { [weak self] e, b in self?.activate(e, b) })
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
        let host = NSHostingView(rootView: OverflowBarView(state: state, size: nil, onArrange: onArrange, feedback: feedback, onActivate: { [weak self] e, b in self?.activate(e, b) }))
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
                // Any mouse-down outside the panel closes it, the menu bar strip included (another app's status item);
                // only our own status item is exempt (its action toggles the panel).
                let p = NSEvent.mouseLocation
                if !panel.frame.contains(p), !self.anchor.insetBy(dx: -1, dy: -1).contains(p) { self.hide("click outside at \(NSStringFromPoint(p))") }
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
        if placeInput(screen) != lastPlaced { place() }
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
    var onArrange: () -> Void = {}
    var feedback: OverflowFeedback?
    var onActivate: (OverflowEntry, ClickButton) -> Void = { _, _ in }
    @AppStorage("overflowShowNames") private var showNames = true

    var body: some View {
        let base = OverflowEntries.make(layout: state.layout, items: state.items, units: state.hideUnits)
        let entries = feedback?.model.rendered(base) ?? base
        Group {
            if entries.isEmpty {
                HStack(spacing: 10) {
                    Text("Nothing hidden").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Arrange…") { onArrange() }
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
            ForEach(Array(entries.enumerated()), id: \.element.key) { i, e in
                if i > 0, entries[i - 1].unit != e.unit || entries[i - 1].kind != e.kind { Divider().frame(height: 16) }
                OverflowEntryView(entry: e, showName: showNames,
                                  together: e.unitSize > 1 ? entries.filter { $0.unit == e.unit }.map(\.displayName) : [],
                                  error: feedback?.errors[e.key], note: feedback?.model.notes[e.key], onActivate: onActivate)
            }
        }
    }
}

struct OverflowEntryView: View {
    let entry: OverflowEntry
    let showName: Bool
    /// Display names of every item hidden with this one (empty when the app has a single item).
    var together: [String] = []
    var error: String?
    var note: String?
    var onActivate: (OverflowEntry, ClickButton) -> Void = { _, _ in }
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2) {
            entryBody
            // Tooltips never show on a non-activating panel: the failure text is drawn inline too.
            if let error {
                Text(error).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 160)
            } else if let note {
                Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 160)
            }
        }
    }

    private var entryBody: some View {
        HStack(spacing: 5) {
            icon.frame(width: 18, height: 18)
            if showName { Text(entry.displayName).font(.system(size: 12)).lineLimit(1) }
            if entry.kind == .notFitting {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if entry.pinnedHidden {
                Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if entry.unitSize > 1 {
                Text("\(entry.unitSize)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 3).background(Capsule().fill(Color.primary.opacity(0.1)))
            }
        }
        .frame(minWidth: entry.width)
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red, lineWidth: error == nil ? 0 : 1.5))
        .overlay(ClickCatcher { button in
            NSLog("[Sommelier] overflow click %@ (%@)", "\(entry.key)", button == .left ? "left" : "right")
            onActivate(entry, button)
        })
        .help(error.map { "Could not open: \($0)" } ?? helpText)
    }

    private var helpText: String {
        if entry.kind == .notFitting { return "Does not fit; macOS moved it into its overflow" }
        if entry.pinnedHidden { return "Kept hidden (always-hidden sibling): " + (together.isEmpty ? entry.displayName : together.joined(separator: ", ")) }
        return together.isEmpty ? entry.displayName : "Hidden together: " + together.joined(separator: ", ")
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


/// Transparent overlay that reports left and right clicks (SwiftUI's tap gesture has no right button).
struct ClickCatcher: NSViewRepresentable {
    let onClick: (ClickButton) -> Void
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onClick = onClick; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onClick = onClick }

    final class CatcherView: NSView {
        var onClick: (ClickButton) -> Void = { _ in }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // Activation starts on mouse-UP so no button is held when the activator posts its own click.
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(.left) } }
        override func rightMouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(.right) } }
    }
}
