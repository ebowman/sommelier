import AppKit
import SommelierCore

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let onSettings: () -> Void
    private let onPermissions: () -> Void

    init(model: AppModel, onSettings: @escaping () -> Void, onPermissions: @escaping () -> Void) {
        self.model = model; self.onSettings = onSettings; self.onPermissions = onPermissions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Sommelier"
        super.init()
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "wineglass", accessibilityDescription: "Sommelier")
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func clicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            model.setShowHidden(!model.state.showHiddenSection)   // gdu.15 refines this
        }
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
        let arrange = NSMenuItem(title: "Arrange…", action: nil, keyEquivalent: "")
        arrange.isEnabled = false   // gdu.19
        m.addItem(arrange)
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
    @objc private func openSettings() { onSettings() }
    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }
    @objc private func openPermissions() { onPermissions() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
