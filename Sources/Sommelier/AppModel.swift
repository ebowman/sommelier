import AppKit
import Observation
import SommelierCore

@MainActor @Observable
final class AppModel {
    let permissions: PermissionsModel
    let state: EngineState
    @ObservationIgnored private(set) var engine: LayoutEngine?
    @ObservationIgnored private(set) var triggers: EngineTriggers?
    var conflictingManager: String?
    @ObservationIgnored var showOnboarding: () -> Void = {}
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var conflictTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []
    @ObservationIgnored private let platform = LivePlatform()
    @ObservationIgnored private let store = FileLayoutStore(url: FileLayoutStore.defaultURL())

    init(permissions: PermissionsModel, state: EngineState = EngineState()) {
        self.permissions = permissions
        self.state = state
        permissions.onAccessibilityGranted = { [weak self] in
            NSLog("[Sommelier] accessibility granted")
            Task { @MainActor in
                guard let self else { return }
                if let engine = self.engine { await engine.clearFailures() }
                await self.startIfReady()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == LivePlatform.bartenderBundleID else { return }
                Task { @MainActor in await self?.bartenderChanged() }
            })
        }
    }

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
                                           log: { NSLog("[Sommelier] engine: %@", $0) })
            engine = e
            triggers = EngineTriggers(engine: e, state: state, scanner: platform, resolve: { [platform] in EngineFactory.dropSelf(platform.resolve($0), bundleID: "ie.boboco.sommelier", moduleName: "Sommelier") })
            watchErrors()
        }
        guard let engine, let triggers else { return }
        await engine.start()
        let fileExists = FileManager.default.fileExists(atPath: store.url.path)
        if state.layout == .empty && !fileExists && state.lastError == nil {
            let observer = RecordingObserver(inner: EngineFactory.makeObserver(platform: platform), ids: BundleIDs(),
                                           transform: { EngineFactory.dropSelf($0, bundleID: "ie.boboco.sommelier", moduleName: "Sommelier") })
            do {
                let resolved = try await observer.observe()
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
