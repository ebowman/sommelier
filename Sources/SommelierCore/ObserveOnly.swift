import Foundation

/// ejb.30: the observe-only switch. While it is ON the whole app reads, decides and displays while changing NOTHING: no drag, no hide/show write,
/// no click, no synthetic input, no file write. Enforced at several layers, every one of them reading the SAME `ObserveOnlyGate` live
/// (`ObserveOnlyActuator`, `ObserveOnlyStore`, the engine's order and membership phases, `LivePlatform`, `ItemActivator`, the app's gestures).
public enum ObserveOnly {
    /// Environment override: "1" FORCES the switch on (it can only make the app safer; nothing can force it off).
    public static let environmentKey = "SOMMELIER_OBSERVE_ONLY"
    /// The app's own preference key (the user's choice).
    public static let defaultsKey = "observeOnly"
    /// The leader of the menu and Arrange status (`CoreStatusText`), so the UI never claims to be active.
    public static let leader = "Observe only: "
    /// What a gesture that would have changed something says instead.
    public static let nothingChanged = "Observe only: nothing was changed"
    /// The Arrange banner while observing, and its button.
    public static let banner = "Observe only \u{2014} Sommelier is not changing anything"
    public static let armButton = "Start arranging\u{2026}"
    public static let forcedNote = "forced by SOMMELIER_OBSERVE_ONLY"
    public static let settingTitle = "Observe only (make no changes)"
    public static let confirmMessage = "Sommelier will start arranging your menu bar: it may drag items and hide or show them."
    public static let confirmStart = "Start arranging"
    public static let confirmStay = "Stay in observe only"

    /// Only the exact value "1" forces it on.
    public static func isOn(_ environment: [String: String]) -> Bool { environment[environmentKey] == "1" }
}

private struct DefaultsBox: @unchecked Sendable { let defaults: UserDefaults; init(_ d: UserDefaults) { defaults = d } }

/// The single source of truth for the observe-only switch. Thread-safe; every guard reads `isOn` at the moment it acts.
/// Production: `production()` (UserDefaults, default ON when the key was never set, env can force ON). Tests inject `init(fixed:)` or `init(stored:...)`.
public final class ObserveOnlyGate: @unchecked Sendable {
    public enum Source: Sendable, Equatable { case defaultOn, setting, env }
    private let lock = NSLock()
    private var stored: Bool?
    private let forced: Bool
    private let persist: @Sendable (Bool) -> Void

    /// `stored` = the user's saved choice (nil = never chosen: ON). `forcedByEnv` = `SOMMELIER_OBSERVE_ONLY=1`. `persist` saves a choice.
    public init(stored: Bool?, forcedByEnv: Bool = false, persist: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.stored = stored; self.forced = forcedByEnv; self.persist = persist
    }
    /// A gate with a fixed starting value and no persistence (engine tests; `Config`'s default is `fixed: false`).
    public convenience init(fixed on: Bool) { self.init(stored: on) }

    /// The app's gate: the user's `observeOnly` preference (absent = ON), forced ON by `SOMMELIER_OBSERVE_ONLY=1`.
    public static func production(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> ObserveOnlyGate {
        let box = DefaultsBox(defaults)
        return ObserveOnlyGate(stored: defaults.object(forKey: ObserveOnly.defaultsKey) as? Bool, forcedByEnv: ObserveOnly.isOn(environment),
                               persist: { box.defaults.set($0, forKey: ObserveOnly.defaultsKey) })   // UserDefaults is thread-safe
    }

    public var isOn: Bool { lock.lock(); defer { lock.unlock() }; return forced || (stored ?? true) }
    public var forcedByEnv: Bool { forced }
    public var source: Source { lock.lock(); defer { lock.unlock() }; return forced ? .env : (stored == nil ? .defaultOn : .setting) }

    /// The launch / switch log line.
    public var logLine: String {
        switch source {
        case .env: return "observe-only: ON (forced by env)"
        case .defaultOn: return "observe-only: ON (default)"
        case .setting: return isOn ? "observe-only: ON (setting)" : "observe-only: OFF (armed by user)"
        }
    }

    /// Turns it on (and remembers the choice). Takes effect at once for every guard.
    public func turnOn() { lock.lock(); stored = true; lock.unlock(); persist(true) }
    /// Turns it off (and remembers the choice). Refused (false) when the environment forces it on: nothing can force it off.
    @discardableResult public func turnOff() -> Bool {
        if forced { return false }
        lock.lock(); stored = false; lock.unlock(); persist(false)
        return true
    }
}

/// Thrown by the low-level write choke points of `LivePlatform` when observe-only is on.
public struct ObserveOnlyRefusal: Error, CustomStringConvertible, Sendable {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var description: String { "observe-only: refused \(what)" }
}

/// How `ObserveOnlyActuator` treats each requirement of `MenuBarActuator`. A new requirement MUST be listed in
/// `ObserveOnlyActuator.classification` (a test compares it with the protocol's source).
public enum ObserveOnlyKind: Sendable { case mutating, readOnly, configuration }

/// The lowest layer of the engine's order and membership path: wraps the real actuator and refuses every call that changes the bar.
/// Deny by default: a requirement added later that has a protocol-extension default is answered by that default (a no-op), never forwarded.
/// While `gate.isOn` it refuses; otherwise it passes through. It is always installed by the engine, so switching needs no re-wiring.
public struct ObserveOnlyActuator: MenuBarActuator {
    public let inner: any MenuBarActuator
    public let gate: ObserveOnlyGate
    public let log: @Sendable (String) -> Void
    public init(inner: any MenuBarActuator, gate: ObserveOnlyGate, log: @escaping @Sendable (String) -> Void) { self.inner = inner; self.gate = gate; self.log = log }

    /// Every requirement of `MenuBarActuator` by name.
    public static let classification: [String: ObserveOnlyKind] = [
        "move": .mutating, "setHidden": .mutating, "applyHiddenBatch": .mutating,
        "lastBatchRespawned": .readOnly, "lastBatchUnconfirmed": .readOnly, "lastBatchRefused": .readOnly, "lastBatchUnsettled": .readOnly,
        "lastMoveTouchedMouse": .readOnly, "lastMoveOpenedStrip": .readOnly,
        "setChurnZone": .configuration, "setRecordOrder": .configuration, "setSingleDrag": .configuration,
        "setEngineInitiated": .configuration, "setStripAllowed": .configuration,
    ]

    private static let refusal = ActuationError.userBusy   // maps to `busy`, nothing posted

    public func move(_ key: ItemKey, relation: Relation) async -> ActuationResult {
        guard gate.isOn else { return await inner.move(key, relation: relation) }
        log("observe-only: would move \(key) \(relation)")
        return .failed(Self.refusal, nil)
    }
    public func setHidden(_ key: ItemKey, _ hidden: Bool) async -> ActuationResult {
        guard gate.isOn else { return await inner.setHidden(key, hidden) }
        log("observe-only: would \(hidden ? "hide" : "show") \(key)")
        return .failed(Self.refusal, nil)
    }
    public func applyHiddenBatch(_ changes: [ItemKey: Bool]) async -> ActuationResult {
        guard gate.isOn else { return await inner.applyHiddenBatch(changes) }
        for (k, h) in changes.sorted(by: { $0.key.description < $1.key.description }) { log("observe-only: would \(h ? "hide" : "show") \(k)") }
        return .failed(Self.refusal, nil)
    }
    public var lastBatchRespawned: Bool { get async { await inner.lastBatchRespawned } }
    public var lastBatchUnconfirmed: Set<ItemKey> { get async { await inner.lastBatchUnconfirmed } }
    public var lastBatchRefused: [ItemKey: String] { get async { await inner.lastBatchRefused } }
    public var lastBatchUnsettled: [ItemKey: String] { get async { await inner.lastBatchUnsettled } }
    public var lastMoveTouchedMouse: Bool { get async { gate.isOn ? false : await inner.lastMoveTouchedMouse } }   // nothing is posted while observing
    public var lastMoveOpenedStrip: Bool { get async { gate.isOn ? false : await inner.lastMoveOpenedStrip } }
    public func setChurnZone(_ keys: Set<ItemKey>) async { await inner.setChurnZone(keys) }
    public func setRecordOrder(_ keys: [ItemKey]) async { await inner.setRecordOrder(keys) }
    public func setSingleDrag(_ on: Bool) async { await inner.setSingleDrag(on) }
    public func setEngineInitiated(_ on: Bool) async { await inner.setEngineInitiated(on) }
    public func setStripAllowed(_ on: Bool) async { await inner.setStripAllowed(on) }
}

/// Wraps the layout store: reads pass through (without the corrupt-file backup write while observing), every write is skipped and logged
/// while `gate.isOn`; with the gate off everything passes through.
public struct ObserveOnlyStore: LayoutStore {
    public let inner: any LayoutStore
    public let gate: ObserveOnlyGate
    public let log: @Sendable (String) -> Void
    public init(inner: any LayoutStore, gate: ObserveOnlyGate, log: @escaping @Sendable (String) -> Void) { self.inner = inner; self.gate = gate; self.log = log }
    public func load() throws -> Layout { gate.isOn ? try inner.loadReadOnly() : try inner.load() }
    public func loadReadOnly() throws -> Layout { try inner.loadReadOnly() }
    public func save(_ layout: Layout) throws {
        guard gate.isOn else { try inner.save(layout); return }
        log("observe-only: would save layout")
    }
    public func backupBeforeMigration() throws -> String? {
        guard gate.isOn else { return try inner.backupBeforeMigration() }
        log("observe-only: would back up the layout before the migration"); return nil
    }
}
