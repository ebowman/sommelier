import Foundation

/// Records each observed item's bundle id (the Control Center tracked key can be the bundle id, not the owner key).
public final class BundleIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [ItemKey: String] = [:]
    public init() {}
    public func record(_ items: [ResolvedItem]) {
        lock.lock(); defer { lock.unlock() }
        for r in items { if let b = r.item.ownerBundleID { map[r.key] = b } }
    }
    public func bundleID(_ k: ItemKey) -> String? { lock.lock(); defer { lock.unlock() }; return map[k] }
}

public struct RecordingObserver: MenuBarObserver {
    public let inner: any MenuBarObserver
    public let ids: BundleIDs
    public let transform: @Sendable ([ResolvedItem]) -> [ResolvedItem]
    public init(inner: any MenuBarObserver, ids: BundleIDs, transform: @escaping @Sendable ([ResolvedItem]) -> [ResolvedItem] = { $0 }) {
        self.inner = inner; self.ids = ids; self.transform = transform
    }
    public func observe() async throws -> [ResolvedItem] { let r = transform(try await inner.observe()); ids.record(r); return r }
    public func observeDetailed(progress: (@Sendable ([ResolvedItem]) -> Void)?) async throws -> BarObservation {
        let t = transform
        var wrapped: (@Sendable ([ResolvedItem]) -> Void)?
        if let progress { wrapped = { @Sendable items in progress(t(items)) } }
        var o = try await inner.observeDetailed(progress: wrapped)
        o.items = t(o.items); ids.record(o.items)
        return o
    }
}

/// Shared live wiring used by the app and `mbprobe apply`. Always drag-only (`allowFallback = false`).
public enum EngineFactory {
    /// The agent also lists our own status item as `module:<name>` (our pid is excluded from the app-extras scan, but not
    /// from MenuBarAgent's hosted children), so drop it by key/bundle id: Sommelier never plans or moves itself.
    public static func dropSelf(_ items: [ResolvedItem], bundleID: String, moduleName: String) -> [ResolvedItem] {
        items.filter { r in
            r.key != .module(name: moduleName) && r.item.ownerBundleID != bundleID && r.ownerKey != bundleID
        }
    }

    public static func makeObserver(platform: LivePlatform, log: @escaping @Sendable (String) -> Void = { _ in }) -> AgreedScanObserver {
        AgreedScanObserver(scanner: platform, resolve: { platform.resolve($0) }, maxScans: 6, deadline: 15,
                           accessibilityTrusted: { platform.accessibilityTrusted() }, log: log)
    }

    /// Control Center tracked entries decide hideability (read-only).
    public static func makeCapabilityRules(bundleIDs: BundleIDs? = nil) -> CapabilityRules {
        makeCapabilityRules(bundleID: { bundleIDs?.bundleID($0) })
    }

    /// Same rules, with the owning bundle id supplied by `bundleID` (the Arrange window reads it from `EngineState.items`).
    public static func makeCapabilityRules(bundleID: @escaping @Sendable (ItemKey) -> String?) -> CapabilityRules {
        let tracked: Set<String>? = (try? ControlCenterTrackedAppsStore().entries())?.map(\.key).reduce(into: Set<String>()) { $0.insert($1) }
        return CapabilityRules(hasTrackedEntry: { key in
            guard let tracked else { return true }
            if case .status(let owner, _) = key { return tracked.contains(owner) || (bundleID(key).map(tracked.contains) ?? false) }
            return false
        })
    }

    @MainActor
    public static func makeLive(platform: LivePlatform = LivePlatform(), store: any LayoutStore, state: EngineState,
                                log: @escaping @Sendable (String) -> Void,
                                selfBundleID: String = "ie.boboco.sommelier", selfModuleName: String = "Sommelier",
                                config: LayoutEngine.Config = LayoutEngine.Config()) -> LayoutEngine {
        let ids = BundleIDs()
        let filter: @Sendable ([ResolvedItem]) -> [ResolvedItem] = { dropSelf($0, bundleID: selfBundleID, moduleName: selfModuleName) }
        let rules = makeCapabilityRules(bundleIDs: ids)
        var lc = LiveActuator.Config()
        lc.allowFallback = false
        let actuator = LiveActuator(platform: platform, config: lc, log: { log("actuator: " + $0) })
        return LayoutEngine(observer: RecordingObserver(inner: makeObserver(platform: platform, log: { log("observer: " + $0) }), ids: ids, transform: filter), actuator: actuator,
                            store: store, capabilities: rules, state: state,
                            busy: { platform.pressedMouseButtons() != 0 },
                            resolveSnapshot: { filter(platform.resolve($0)) }, log: log, config: config)
    }
}
