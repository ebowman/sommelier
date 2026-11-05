import Foundation

/// Click logic of the inline "show the rest" mode (docs/architecture.md, App shell). Pure main-actor model: the status item
/// forwards clicks, the auto re-hide monitor calls `rehide`, the app calls `stateChanged()` when `EngineState.revealedObserved`
/// changes. It never decides what is shown; it only sets the engine's reveal request and times click -> converged.
@MainActor
public final class RevealController {
    public enum ClickResult: Equatable, Sendable {
        /// A reveal was requested (`alwaysHidden`: option-click, both sections).
        case revealed(alwaysHidden: Bool)
        /// A click while revealed (or while a reveal is pending): re-hide requested at once.
        case rehidden
        /// Inside the debounce window of the previous accepted click.
        case ignored
    }

    /// Clicks closer than this to the previous accepted click are ignored (a reveal pass is in flight).
    public static let debounce: Duration = .milliseconds(300)

    private let state: EngineState
    private let apply: (_ hidden: Bool, _ alwaysHidden: Bool) -> Void
    private let now: () -> ContinuousClock.Instant
    private let log: (String) -> Void
    private var lastAccepted: ContinuousClock.Instant?
    private var clickAt: ContinuousClock.Instant?
    /// Click -> observed reveal of the latest reveal click, in milliseconds (nil until converged).
    public private(set) var lastConvergeMillis: Int?

    public init(state: EngineState, apply: @escaping (_ hidden: Bool, _ alwaysHidden: Bool) -> Void,
                now: @escaping () -> ContinuousClock.Instant = { .now }, log: @escaping (String) -> Void = { _ in }) {
        self.state = state; self.apply = apply; self.now = now; self.log = log
    }

    /// A reveal is requested of the engine (not necessarily observed yet).
    public var requested: Bool { state.showHiddenSection || state.showAlwaysHidden }

    @discardableResult
    public func click(option: Bool) -> ClickResult {
        let t = now()
        if let last = lastAccepted, last.duration(to: t) < Self.debounce { return .ignored }
        lastAccepted = t
        if requested || state.revealedObserved {
            clickAt = nil
            apply(false, false)
            return .rehidden
        }
        clickAt = t
        lastConvergeMillis = nil
        state.revealNotice = nil
        apply(true, option)
        return .revealed(alwaysHidden: option)
    }

    /// Auto re-hide (timer, menu closed). No-op unless something is requested or still observed as revealed.
    public func rehide(reason: String) {
        guard requested || state.revealedObserved else { return }
        log("re-hide: \(reason)")
        clickAt = nil
        apply(false, false)
    }

    /// A requested reveal that never showed anything (refused batch, nothing applicable) is withdrawn with visible feedback:
    /// a log line and `EngineState.revealNotice` (Arrange status line).
    public func withdraw(reason: String) {
        let layout = state.layout
        var wanted: [ItemKey] = []
        if state.showHiddenSection { wanted += layout.hidden }
        if state.showAlwaysHidden { wanted += layout.alwaysHidden }
        let onBar = Set(state.observed.onBar)
        let n = wanted.filter { !onBar.contains($0) }.count
        let text = "Reveal withdrawn: \(n) item\(n == 1 ? "" : "s") could not be shown"
        log("\(text) (\(reason))")
        rehide(reason: reason)
        state.revealNotice = text
    }

    /// Call when `state.revealedObserved` (or the request) changed: records click -> converged once per reveal click.
    public func stateChanged() {
        guard let c = clickAt, state.revealedObserved, requested else { return }
        let d = c.duration(to: now()).components
        let ms = Int(d.seconds) * 1000 + Int(d.attoseconds / 1_000_000_000_000_000)
        lastConvergeMillis = ms
        clickAt = nil
        log("reveal converged \(ms) ms after the click")
    }
}
