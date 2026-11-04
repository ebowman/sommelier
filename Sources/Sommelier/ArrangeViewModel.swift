import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import SommelierCore

/// Drag payload: the item's store key as plain text.
struct ArrangePayload: Transferable, Equatable {
    var storeKey: String
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.storeKey }, importing: { ArrangePayload(storeKey: $0) })
    }
}

/// Maps `EngineState` + `ArrangeLayout` to rows (via the pure `ArrangeSections`) and turns user gestures into `engine.setLayout`.
///
/// Truthfulness rules (docs/architecture.md, "Arrange window"):
/// - The Visible strip is the OBSERVED bar. A requested move never reorders it; the moved unit shows as a ghost at the
///   target slot, and its real capsule shows a spinner until a settled pass AND the observed order agree.
/// - Hidden / Always hidden follow the layout (our own data) and reorder at once.
/// - Every engine call is a `Task`; the main actor only renders and submits.
@MainActor @Observable
final class ArrangeViewModel {
    struct Awaiting { var pass: Int; var since: Date }
    enum Confirm: Identifiable {
        case adopt(ArrangeLayout)
        case hideNotFitting(ArrangeLayout, titles: [String], blocked: [String])
        var id: String {
            switch self {
            case .adopt: return "adopt"
            case .hideNotFitting: return "hide"
            }
        }
    }

    let state: EngineState
    @ObservationIgnored private unowned let model: AppModel
    var filter = ""
    var message: String?
    var confirm: Confirm?
    /// Slot currently targeted by a drag, for the insertion indicator.
    var hoverSlot: (section: LayoutSection, slot: Int)?
    private(set) var awaiting: [ItemKey: Awaiting] = [:]
    private(set) var timedOut: Set<ItemKey> = []
    /// The layout we submitted until the engine has published it (so rapid consecutive drops build on each other).
    private(set) var pendingLayout: ArrangeLayout?
    private(set) var capabilities: CapabilityRules
    @ObservationIgnored private var capPass = -1
    @ObservationIgnored private var capItems = -1
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var windowVisible = false
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    static let timeoutSeconds: TimeInterval = 90

    init(model: AppModel) {
        self.model = model
        self.state = model.state
        capabilities = EngineFactory.makeCapabilityRules(bundleID: { _ in nil })
    }

    var layout: ArrangeLayout { pendingLayout ?? state.layout }

    var content: ArrangeContent {
        ArrangeSections.make(observed: state.observed, layout: layout, items: state.items, perItem: state.perItem,
                             capabilities: { [capabilities] in capabilities.capability(for: $0) },
                             showHiddenSection: state.showHiddenSection, awaiting: Set(awaiting.keys), timedOut: timedOut, filter: filter)
    }

    var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasNotFitting: Bool { !state.observed.systemOverflow.isEmpty }
    var statusText: String {
        ArrangeSections.statusLine(perItem: state.perItem, lastError: state.lastError, isConverged: state.isConverged,
                                   inFlight: state.inFlight != nil, pendingAwaiting: awaiting.count)
    }
    var isPaused: Bool { model.isPaused }
    private var cap: (ItemKey) -> Capability { { [capabilities] in capabilities.capability(for: $0) } }

    // MARK: lifecycle

    func start() {
        windowVisible = true
        refreshCapabilities(force: true)
        ensureTimer()
    }

    func stop() { windowVisible = false }

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func refreshCapabilities(force: Bool = false) {
        guard force || state.passCount != capPass || state.items.count != capItems else { return }
        capPass = state.passCount; capItems = state.items.count
        let ids = state.items.compactMapValues(\.ownerBundleID)
        capabilities = EngineFactory.makeCapabilityRules(bundleID: { ids[$0] })
    }

    private func tick() {
        let t = Date()
        if let last = lastTick, t.timeIntervalSince(last) > 0.75 {
            NSLog("[Sommelier] arrange: MAIN ACTOR STALL: %.2fs between 0.25s ticks", t.timeIntervalSince(last))
        }
        lastTick = t
        guard windowVisible || !awaiting.isEmpty || pendingLayout != nil else { return }
        refreshCapabilities()
        if let p = pendingLayout, state.layout == p { pendingLayout = nil }
        let now = Date()
        for (k, a) in awaiting {
            guard layout.section(of: k) != nil else { awaiting[k] = nil; continue }
            switch state.perItem[k] {
            case .failed(let e)?:
                awaiting[k] = nil
                NSLog("[Sommelier] arrange: %@ FAILED after %.1fs: %@", "\(k)", now.timeIntervalSince(a.since), ArrangeSections.describe(e))
            case .unsupported(let r)?:
                awaiting[k] = nil
                NSLog("[Sommelier] arrange: %@ unsupported after %.1fs: %@", "\(k)", now.timeIntervalSince(a.since), r)
            case let st? where (st == .inPlace || st == .notFitting) && pendingLayout == nil && state.passCount > a.pass
                && ArrangeSections.placementMatches(k, layout: layout, observed: state.observed, showHiddenSection: state.showHiddenSection):
                awaiting[k] = nil
                timedOut.remove(k)
                NSLog("[Sommelier] arrange: %@ verified in place %.1fs after the drop (observed order matches)", "\(k)", now.timeIntervalSince(a.since))
            default:
                if now.timeIntervalSince(a.since) > Self.timeoutSeconds, !timedOut.contains(k) {
                    timedOut.insert(k)
                    NSLog("[Sommelier] arrange: %@ NOT applied after %.0fs", "\(k)", Self.timeoutSeconds)
                }
            }
        }
        if windowVisible { logRowsIfChanged() }
    }

    /// One line per change of what the window shows (the "truth log" used for live verification).
    private func logRowsIfChanged() {
        func line(_ s: ArrangeStrip) -> String {
            s.rows.map { r in (r.isBoundary ? "|OVERFLOW|" : r.title + (r.isGhost ? "(ghost)" : "") + r.badge.glyph) }.joined(separator: " ")
        }
        let c = content
        let sig = "V[\(line(c.visible))] H[\(line(c.hidden))] A[\(line(c.alwaysHidden))]"
        guard sig != lastSignature else { return }
        lastSignature = sig
        NSLog("[Sommelier] arrange rows: %@  status=%@", sig, statusText)
    }

    // MARK: gestures

    func drop(_ payloads: [ArrangePayload], section: LayoutSection, slot: Int) -> Bool {
        hoverSlot = nil
        guard !isFiltering, let p = payloads.first, let key = ItemKey(storeKey: p.storeKey) else { return false }
        let rows = content.strip(section).rows
        let outcome = ArrangeDrop.drop(layout: layout, rows: rows, slot: slot, key: key, section: section, capabilities: cap)
        NSLog("[Sommelier] arrange: drop %@ -> %@ slot %d", "\(key)", section.rawValue, slot)
        return submit(outcome, key: key)
    }

    func move(_ key: ItemKey, to section: LayoutSection) {
        _ = submit(ArrangeDrop.outcome(layout: layout, key: key, to: section, index: nil, capabilities: cap), key: key)
    }

    func canMove(_ key: ItemKey, to section: LayoutSection) -> Bool {
        guard layout.section(of: key) != section else { return false }   // already there (menu item stays disabled)
        if case .move = ArrangeDrop.outcome(layout: layout, key: key, to: section, index: nil, capabilities: cap) { return true }
        return false
    }

    func step(_ key: ItemKey, _ dir: ArrangeDrop.Direction) {
        _ = submit(ArrangeDrop.step(layout: layout, rows: content.visible.rows, key: key, dir, capabilities: cap), key: key)
    }

    func canStep(_ key: ItemKey, _ dir: ArrangeDrop.Direction) -> Bool {
        if case .move = ArrangeDrop.step(layout: layout, rows: content.visible.rows, key: key, dir, capabilities: cap) { return true }
        return false
    }

    /// Debug path (`SOMMELIER_ARRANGE_MOVE="<storeKey>|<visible|hidden|always>|<index or ->"`): the same pipeline as a drop.
    /// Several moves may be chained with ";" and spaced by `SOMMELIER_ARRANGE_MOVE_INTERVAL` seconds (default 0).
    func runEnvMove(_ spec: String, after delay: Duration) {
        let interval = Double(ProcessInfo.processInfo.environment["SOMMELIER_ARRANGE_MOVE_INTERVAL"] ?? "") ?? 0
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            // Wait for the engine and a first observation (up to 90 s).
            for _ in 0..<180 {
                guard let self else { return }
                if self.model.engine != nil, self.state.passCount > 0, self.state.layout != .empty { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            for one in spec.components(separatedBy: ";") where !one.isEmpty {
                guard let self else { return }
                let parts = one.components(separatedBy: "|")
                guard parts.count >= 3, let key = ItemKey(storeKey: parts.dropLast(2).joined(separator: "|")) else {
                    NSLog("[Sommelier] arrange env move: bad spec %@", one); continue
                }
                let section: LayoutSection? = ["visible": .visible, "hidden": .hidden, "always": .alwaysHidden, "alwaysHidden": .alwaysHidden][parts[parts.count - 2]]
                let index = Int(parts[parts.count - 1])
                guard let section else { NSLog("[Sommelier] arrange env move: bad section in %@", one); continue }
                self.ensureTimer()
                NSLog("[Sommelier] arrange env move: %@ -> %@ index %@", "\(key)", section.rawValue, index.map(String.init) ?? "-")
                _ = self.submit(ArrangeDrop.outcome(layout: self.layout, key: key, to: section, index: index, capabilities: self.cap), key: key)
                if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
            }
        }
    }

    @discardableResult
    private func submit(_ outcome: ArrangeDrop.Outcome, key: ItemKey) -> Bool {
        switch outcome {
        case .noop:
            message = nil
            NSLog("[Sommelier] arrange: %@ dropped on its own position: no change", "\(key)")
            return true
        case .rejected(let why):
            message = why
            NSLog("[Sommelier] arrange: rejected %@: %@", "\(key)", why)
            return false
        case .move(let l, let moved, let willNotFit):
            let old = layout
            message = willNotFit ? "Dropped left of the overflow boundary: macOS will keep it behind the chevron." : nil
            for k in moved {
                let was = old.section(of: k), now = l.section(of: k)
                if was == now, now != .visible { continue }   // pure reorder inside a hidden strip: our data, nothing to verify
                awaiting[k] = Awaiting(pass: state.passCount, since: Date())
                timedOut.remove(k)
            }
            NSLog("[Sommelier] arrange: submit layout; moved=%@", moved.map { "\($0)" }.joined(separator: ", "))
            apply(l)
            return true
        }
    }

    private func apply(_ l: ArrangeLayout) {
        guard let engine = model.engine else { message = "The layout engine is not running."; return }
        pendingLayout = l
        ensureTimer()
        Task { await engine.setLayout(l) }   // never block the main actor on the engine
    }

    // MARK: toolbar and menu actions

    func reapply() {
        guard let engine = model.engine else { return }
        timedOut = []
        Task { await engine.clearFailures(); await engine.requestReconcile() }
    }

    func retry(_ key: ItemKey) {
        guard let engine = model.engine else { return }
        timedOut.remove(key)
        Task { await engine.clearFailures(); await engine.requestReconcile() }
    }

    func askAdopt() { confirm = .adopt(ArrangeDrop.adopt(observed: state.observed, current: layout)) }

    func askHideNotFitting() {
        let r = ArrangeDrop.hideNotFitting(layout: layout, observed: state.observed, capabilities: cap)
        let c = content
        func t(_ k: ItemKey) -> String { (c.visible.rows + c.hidden.rows + c.alwaysHidden.rows).first { $0.key == k }?.title ?? ArrangeSections.fallbackTitle(k) }
        confirm = .hideNotFitting(r.layout, titles: r.moved.map(t), blocked: r.blocked.map(t))
    }

    func confirmed(_ c: Confirm) {
        confirm = nil
        switch c {
        case .adopt(let l):
            NSLog("[Sommelier] arrange: adopt current order")
            awaiting = [:]; timedOut = []
            apply(l)
        case .hideNotFitting(let l, let titles, _):
            NSLog("[Sommelier] arrange: hide what does not fit: %@", titles.joined(separator: ", "))
            let old = layout
            for k in l.hidden where old.section(of: k) == .visible { awaiting[k] = Awaiting(pass: state.passCount, since: Date()) }
            apply(l)
        }
    }

    /// "Reveal in menu bar" is the section-wide hidden toggle (not per item): a transient per-item layout would be
    /// persisted by `setLayout` and could outlive the app. It re-hides after `autoRehideSeconds`.
    func reveal() {
        guard let engine = model.engine else { return }
        revealTask?.cancel()
        let secs = UserDefaults.standard.object(forKey: "autoRehideSeconds") as? Int ?? 10
        revealTask = Task {
            await engine.setShowHiddenSection(true)
            guard secs > 0 else { return }
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled { await engine.setShowHiddenSection(false) }
        }
        message = "Revealing all hidden items" + (secs > 0 ? " for \(secs) s (the toggle is section-wide)." : ".")
    }
}
