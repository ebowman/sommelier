import AppKit
import Observation
import SommelierCore

@MainActor @Observable
final class AppModel {
    let permissions: PermissionsModel
    let state: EngineState
    @ObservationIgnored private(set) var engine: LayoutEngine?
    @ObservationIgnored private(set) var triggers: EngineTriggers?
    @ObservationIgnored private(set) var agentWatcher: MenuBarAgentWatcher?
    /// Called on every display configuration change (the status item controller repositions an open overflow panel).
    @ObservationIgnored var onDisplayChange: () -> Void = {}
    var conflictingManager: String?
    @ObservationIgnored var showOnboarding: () -> Void = {}
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var conflictTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []
    @ObservationIgnored private let platform = LivePlatform()
    /// `SOMMELIER_LAYOUT_FILE=<path>` keeps dev runs away from ~/Library/Application Support/Sommelier/layout.json.
    @ObservationIgnored private let store: FileLayoutStore

    init(permissions: PermissionsModel, state: EngineState = EngineState()) {
        self.permissions = permissions
        self.state = state
        if let p = ProcessInfo.processInfo.environment["SOMMELIER_LAYOUT_FILE"], !p.isEmpty {
            store = FileLayoutStore(url: URL(fileURLWithPath: (p as NSString).expandingTildeInPath))
        } else {
            store = FileLayoutStore(url: FileLayoutStore.defaultURL())
        }
        NSLog("[Sommelier] layout file: %@", store.url.path)
        permissions.onAccessibilityGranted = { [weak self] in
            NSLog("[Sommelier] accessibility granted")
            Task { @MainActor in
                guard let self else { return }
                if let engine = self.engine { await engine.clearFailures() }
                await self.startIfReady()
            }
        }
        // Display changes (unplug/replug, resolution, notch screen): a burst of notifications becomes ONE reconcile after 1 s
        // (the engine replaces a pending request with the same reason); the strip is recomputed from the next agent read.
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displayChanged() }
        })
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == LivePlatform.bartenderBundleID else { return }
                Task { @MainActor in await self?.bartenderChanged() }
            })
        }
    }

    @ObservationIgnored private var activator: ItemActivator?

    /// Opens the real menu of a hidden item (overflow panel click-forwarding). On a vanished item the engine refreshes.
    func activate(_ key: ItemKey, button: ClickButton) async -> ActivationResult {
        guard let engine else { return .failed(.unavailable("Sommelier is not running yet")) }
        if activator == nil {
            // The engine's own platform: one scanner and one ScanState, so assumed-hidden records are shared and never overwritten.
            let live = LiveActivationPlatform(platform: platform, closeMonitor: NSEventCloseMonitor(),
                                              filter: { EngineFactory.dropSelf($0, bundleID: "ie.boboco.sommelier", moduleName: "Sommelier") })
            activator = ItemActivator(platform: live, hold: engine, log: { NSLog("[Sommelier] activator: %@", $0) })
        }
        guard let activator else { return .failed(.unavailable("no activator")) }
        let r = await activator.activate(key: key, button: button)
        switch r {
        case .failed(.notRunning), .failed(.notFound): await engine.requestReconcile(supersede: true, reason: "activation failed")
        default: break
        }
        return r
    }

    var isPaused: Bool { conflictingManager != nil }

    var trusted: Bool { permissions.isReady }

    var statusText: String {
        StatusLine.text(state: state, trusted: trusted, conflicting: conflictingManager)
    }

    var newItemPolicy: NewItemPolicy {
        get { state.layout.newItemPolicy }
        set {
            var l = state.layout
            l.newItemPolicy = newValue
            guard let engine else { return }
            Task { await engine.setLayout(l) }
        }
    }

    func setShowHidden(_ on: Bool) {
        guard let engine else { return }
        Task { await engine.setShowHiddenSection(on) }
    }

    func startIfReady() async {
        permissions.refresh()
        NSLog("[Sommelier] startIfReady trusted=\(permissions.isReady)")
        guard permissions.isReady else { showOnboarding(); return }
        guard !starting else { return }
        starting = true
        defer { starting = false }
        if let m = platform.conflictingManager() {
            conflictingManager = m
            NSLog("[Sommelier] paused: \(m)")
            pollConflict()
            return
        }
        conflictingManager = nil
        conflictTask?.cancel(); conflictTask = nil
        if engine == nil {
            let e = EngineFactory.makeLive(platform: platform, store: store, state: state,
                                           log: { NSLog("[Sommelier] engine: %@", $0) },
                                           allowAgentRestart: { UserDefaults.standard.object(forKey: "allowAgentRestart") as? Bool })
            engine = e
            triggers = EngineTriggers(engine: e, state: state, scanner: platform, resolve: { [platform] in EngineFactory.dropSelf(platform.resolve($0), bundleID: "ie.boboco.sommelier", moduleName: "Sommelier") },
                                       log: { NSLog(($0.hasPrefix("launch") || $0.hasPrefix("quit") || $0.hasPrefix("notification")) ? "[Sommelier] apps: %@" : "[Sommelier] poll: %@", $0) },
                                       ownerPIDs: { [state] in
                                           let pids = Set(state.items.values.map { Int32($0.ownerPID) })
                                           return pids.isEmpty ? nil : pids
                                       })
            watchErrors()
            agentWatcher = MenuBarAgentWatcher(log: { NSLog("[Sommelier] %@", $0) },
                                                busy: { [platform] in platform.agentRestartInProgress },
                                                isExpected: { [platform] in platform.isOwnAgentPID($0) }, onChange: { [platform, weak self] _, _ in
                platform.invalidateAgentState()
                await self?.engine?.agentRestarted()
            })
        }
        guard let engine, let triggers else { return }
        await engine.start()
        let fileExists = FileManager.default.fileExists(atPath: store.url.path)
        if state.layout == .empty && !fileExists && state.lastError == nil {
            let observer = RecordingObserver(inner: EngineFactory.makeObserver(platform: platform), ids: BundleIDs(),
                                           transform: { EngineFactory.dropSelf($0, bundleID: "ie.boboco.sommelier", moduleName: "Sommelier") })
            do {
                // The first scan is shown at once (unsettled); the layout itself is only written from a settled read.
                let reading = try await observer.observeDetailed(progress: { items in Task { await engine.showProvisional(items) } })
                guard reading.settled else {
                    // Two scans never agreed (gdu.46): do not persist a layout from a guess; the engine's pass adopts new items
                    // visible at the end in observed order once an observation settles.
                    NSLog("[Sommelier] first-launch scan unsettled after \(reading.scans) scans; layout left empty")
                    throw ObserveError.noAgreement(scans: reading.scans)
                }
                let resolved = reading.items
                let (layout, excluded) = LayoutBuilder.build(from: resolved)
                await engine.setLayout(layout)
                NSLog("[Sommelier] initialized layout from current order (\(layout.keys(in: .visible).count + layout.keys(in: .hidden).count) keys; excluded \(excluded.count))")
                let selfKeys = (layout.keys(in: .visible) + layout.keys(in: .hidden)).filter { "\($0)".lowercased().contains("sommelier") }
                NSLog("[Sommelier] own item in layout: \(selfKeys.isEmpty ? "none" : selfKeys.map { "\($0)" }.joined(separator: ","))")
            } catch {
                NSLog("[Sommelier] first-launch scan failed: \(error)")
            }
        }
        await engine.requestReconcile()
        triggers.start()
        agentWatcher?.start()
    }

    private func displayChanged() {
        NSLog("[Sommelier] display configuration changed (%d screen(s)); reconcile in 1 s", NSScreen.screens.count)
        platform.invalidateStrip()
        onDisplayChange()
        guard let engine else { return }
        Task { await engine.scheduleReconcile(after: .seconds(1), reason: "display change") }
    }

    private func pollConflict() {
        conflictTask?.cancel()
        conflictTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                if self.platform.conflictingManager() == nil {
                    self.conflictTask = nil
                    await self.startIfReady()
                    return
                }
            }
        }
    }

    private func bartenderChanged() async {
        if let m = platform.conflictingManager() {
            NSLog("[Sommelier] \(m); pausing")
            conflictingManager = m
            triggers?.stop()
            agentWatcher?.stop()
            pollConflict()
        } else if conflictingManager != nil {
            NSLog("[Sommelier] Bartender gone; resuming")
            await startIfReady()
        }
    }

    /// Watches for permissionDenied: stop triggers and show onboarding.
    private func watchErrors() {
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.state.lastError == .permissionDenied, self.triggers != nil {
                    NSLog("[Sommelier] permissionDenied; stopping triggers")
                    self.triggers?.stop()
                    self.agentWatcher?.stop()
                    self.showOnboarding()
                    while self.state.lastError == .permissionDenied, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        self.permissions.refresh()
                        if self.permissions.isReady {
                            await self.engine?.clearFailures()
                            await self.startIfReady()
                        }
                    }
                }
            }
        }
    }
}
