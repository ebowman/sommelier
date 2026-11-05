import AppKit
import SommelierCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private lazy var panel: OverflowPanelController = OverflowPanelController(state: model.state, onArrange: { [weak self] in
        self?.panel.hide("arrange")
        self?.onArrange()
    }, onActivate: { [weak self] key, button in
        guard let self else { return .failed(.unavailable("Sommelier is closing")) }
        return await self.model.activate(key, button: button)
    })
    private lazy var autoRehide = RevealAutoRehide(state: model.state, controller: model.reveal,
                                                    ownFrame: { [weak self] in self?.statusItem.button?.window?.frame })
    private let onSettings: () -> Void
    private let onArrange: () -> Void
    private let onPermissions: () -> Void

    init(model: AppModel, onSettings: @escaping () -> Void, onArrange: @escaping () -> Void, onPermissions: @escaping () -> Void) {
        self.model = model; self.onSettings = onSettings; self.onArrange = onArrange; self.onPermissions = onPermissions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Sommelier"
        super.init()
        if let b = statusItem.button {
            b.setAccessibilityIdentifier(MenuBarScanner.ownStatusItemIdentifier)
            b.image = NSImage(systemSymbolName: "wineglass", accessibilityDescription: "Sommelier")
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeReveal()
    }

    @objc private func clicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            if UserDefaults.standard.string(forKey: "revealMode") == "inline" {
                let r = model.reveal.click(option: ev?.modifierFlags.contains(.option) == true)
                NSLog("[Sommelier] reveal click: %@", "\(r)")
            } else {
                togglePanel()
            }
        }
    }

    /// Icon and auto re-hide follow the engine's OBSERVED reveal state (`wineglass.fill` once the reveal pass has converged,
    /// including a partial one); the request alone changes nothing visible. Re-arms itself on every change.
    private func observeReveal() {
        let st = model.state
        withObservationTracking {
            _ = st.revealedObserved; _ = st.showHiddenSection; _ = st.showAlwaysHidden
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyRevealState()
                self.observeReveal()
            }
        }
    }

    private func applyRevealState() {
        let st = model.state
        let name = st.revealedObserved ? "wineglass.fill" : "wineglass"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Sommelier")
        if st.showHiddenSection || st.showAlwaysHidden { autoRehide.start() }
        model.reveal.stateChanged()
        NSLog("[Sommelier] reveal state: requested=%@ always=%@ observed=%@ icon=%@", "\(st.showHiddenSection)", "\(st.showAlwaysHidden)", "\(st.revealedObserved)", name)
    }

    /// Display change: an open overflow panel follows the status item to its (possibly new) screen.
    func displayChanged() {
        guard panel.isVisible else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))   // the status item's window frame settles after the reconfiguration
            guard let self, let w = self.statusItem.button?.window, let screen = w.screen ?? NSScreen.main else { return }
            self.panel.reposition(anchoredTo: w.frame, on: screen)
        }
    }

    func togglePanel() {
        guard let w = statusItem.button?.window else { return }
        guard let screen = w.screen ?? NSScreen.main else { return }
        panel.toggle(anchoredTo: w.frame, on: screen)
    }

    /// Verification aid (SOMMELIER_OPEN_PANEL=1): open the panel and log its frame and entries.
    func openPanelForVerification() {
        if !panel.isVisible { togglePanel() }
        logPanel()
        for delay in [8.0, 16.0] {   // the engine needs a while to converge; log the live state again
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.logPanel() }
        }
    }

    private func logPanel() {
        let names = panel.entries.map(\.displayName).joined(separator: " | ")
        NSLog("[Sommelier] panel frame=%@ item=%@ entries(%d)=%@", NSStringFromRect(panel.frame ?? .zero),
              NSStringFromRect(statusItem.button?.window?.frame ?? .zero), panel.entries.count, names)
    }

    func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        m.addItem(.separator())
        let show = item("Show hidden items", #selector(toggleHidden))
        show.state = model.state.showHiddenSection ? .on : .off
        m.addItem(show)
        m.addItem(item("Arrange…", #selector(openArrange)))
        m.addItem(item("Settings…", #selector(openSettings), key: ","))
        let login = item("Start at login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(item("Permissions…", #selector(openPermissions)))
        m.addItem(item("Quit", #selector(quit), key: "q"))
        return m
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleHidden() { model.setShowHidden(!model.state.showHiddenSection) }
    @objc private func openArrange() { onArrange() }
    @objc private func openSettings() { onSettings() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }
    @objc private func openPermissions() { onPermissions() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
