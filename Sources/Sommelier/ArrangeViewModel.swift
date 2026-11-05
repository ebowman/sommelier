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
    enum Confirm: Identifiable {
        /// `base`: the engine layout revision the dialog's layout was composed on (when it opened), passed as `setLayout(basedOn:)`.
        case adopt(ArrangeLayout, base: Int)
        case hideNotFitting(ArrangeLayout, titles: [String], blocked: [String], base: Int)
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
    /// The waiting state machine (pure, in SommelierCore); this class only feeds it.
    private(set) var tracker = ArrangeTracker()
    /// The layout we submitted until the engine has published it (by revision, gdu.48); rapid consecutive drops build on it.
    private(set) var pending = PendingLayout()
    /// Capability rules derived from `state.items`; refreshed on demand (see `cap`), never only while the window is open.
    @ObservationIgnored private var capabilities: CapabilityRules
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

    /// The layout further drops build on: the engine's, or the pending copy rebased onto it (the engine's additions survive).
    var layout: ArrangeLayout { pending.effective(over: state.layout) }

    /// The engine's hide-unit rule (gdu.75): drops and the unit note group exactly like the planner.
    private var units: HideUnitRule { state.hideUnits }

    var observationProblem: String? { ArrangeSections.observationProblem(lastError: state.lastError) }
    /// False while the bar has no trustworthy observation (none yet, or the last one failed/disagreed).
    var observationAvailable: Bool { !state.observed.onBar.isEmpty && observationProblem == nil }

    var content: ArrangeContent {
        ArrangeSections.make(observed: state.observed, layout: layout, items: state.items, perItem: state.perItem,
                             capabilities: cap, showHiddenSection: state.showHiddenSection,
                             awaiting: tracker.awaiting, timedOut: tracker.timedOut,
                             suppressedStatus: tracker.suppressed(passSequence: state.passSequence, observationSettled: state.observationSettled),
                             pendingConfirmation: state.pendingConfirmation,
                             observationProblem: observationProblem, filter: filter, units: units,
                             unitAppName: HideUnitNames.runningAppName)
    }

    var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasNotFitting: Bool { !state.observed.systemOverflow.isEmpty }
    var statusText: String {
        ArrangeSections.statusLine(perItem: state.perItem, lastError: state.lastError, isConverged: state.isConverged,
                                   inFlight: state.inFlight != nil, pendingAwaiting: tracker.entries.count,
                                   observationSettled: state.observationSettled, notice: state.revealNotice ?? ArrangeSections.revealSkipNotice(state: state) ?? state.unsettledNotice ?? state.orderNotAppliedNotice ?? state.newItemNotice ?? selfPositioningNote,
                                   pollPausedNames: pollPausedNames)
    }
    /// gdu.67: shown after the engine rewrote a layout that straddled a self-positioning item (`lastNormalization` holds only those keys then).
    private var selfPositioningNote: String? {
        let keys = state.lastNormalization
        guard !keys.isEmpty, keys.allSatisfy({ SelfPositioning.isSelfPositioning($0) }) else { return nil }
        let names = keys.map { displayName($0) }.joined(separator: ", ")
        return "Layout adjusted around \(names): it positions itself, so items cannot sit on both sides of it."
    }
    /// Display names of the items whose flapping paused the poll, nil when it is not paused (gdu.58).
    private var pollPausedNames: [String]? {
        guard let s = state.pollSuppression else { return nil }
        return ArrangeSections.pollPausedNames(suppression: s, items: state.items, now: Date())
    }
    var isPaused: Bool { model.isPaused }
    /// Capability only from the engine's own data; a key without `ItemInfo` is unknown, hence allowed (engine decides).
    private var cap: (ItemKey) -> Capability {
        refreshCapabilities()
        return { [capabilities, items = state.items] in ArrangeCapabilities.resolve($0, items: items, rules: capabilities) }
    }

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
        capabilities = ArrangeCapabilities.rules(items: state.items, resolver: EngineFactory.currentTrackedResolver())
    }

    private func tick() {
        let t = Date()
        if let last = lastTick, t.timeIntervalSince(last) - 0.25 > 0.1 {
            NSLog("[Sommelier] arrange: MAIN ACTOR STALL: timer %.0f ms late", (t.timeIntervalSince(last) - 0.25) * 1000)
        }
        lastTick = t
        // The pause text hides itself when its window ends (gdu.60): `statusText` re-reads the clock, this makes the view re-render.
        if let until = state.pollSuppression?.until, until <= t, windowVisible { state.pollSuppression = nil }
        guard windowVisible || !tracker.isEmpty || pending.isActive else { return }
        refreshCapabilities()
        pending.resolve(stateRevision: state.layoutRevision)
        guard !pending.isActive else { if windowVisible { logRowsIfChanged() }; return }
        for line in tracker.update(observed: state.observed, layout: layout, perItem: state.perItem, passSequence: state.passSequence,
                                   showHiddenSection: state.showHiddenSection, now: t,
                                   observationSettled: state.observationSettled) {
            NSLog("[Sommelier] arrange: %@", line)
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
        let outcome = ArrangeDrop.drop(layout: layout, rows: rows, slot: slot, key: key, section: section, capabilities: cap,
                                       observationAvailable: observationAvailable,
                                       bar: state.observed.onBar, displayName: displayName, units: units)
        NSLog("[Sommelier] arrange: drop %@ -> %@ slot %d", "\(key)", section.rawValue, slot)
        return submit(outcome, key: key)
    }

    func move(_ key: ItemKey, to section: LayoutSection) {
        _ = submit(ArrangeDrop.outcome(layout: layout, key: key, to: section, index: nil, capabilities: cap,
                                       observationAvailable: observationAvailable, units: units), key: key)
    }

    /// Item name for refusal texts: the engine's `ItemInfo` when known, else the key.
    private var displayName: (ItemKey) -> String {
        { [items = state.items] k in items[k].map(OverflowEntries.displayName) ?? "\(k)" }
    }

    func canMove(_ key: ItemKey, to section: LayoutSection) -> Bool {
        guard layout.section(of: key) != section else { return false }   // already there (menu item stays disabled)
        if case .move = ArrangeDrop.outcome(layout: layout, key: key, to: section, index: nil, capabilities: cap,
                                            observationAvailable: observationAvailable, units: units) { return true }
        return false
    }

    func step(_ key: ItemKey, _ dir: ArrangeDrop.Direction) {
        _ = submit(ArrangeDrop.step(layout: layout, rows: content.visible.rows, key: key, dir, capabilities: cap,
                                    observationAvailable: observationAvailable, bar: state.observed.onBar, displayName: displayName, units: units), key: key)
    }

    func canStep(_ key: ItemKey, _ dir: ArrangeDrop.Direction) -> Bool {
        if case .move = ArrangeDrop.step(layout: layout, rows: content.visible.rows, key: key, dir, capabilities: cap,
                                         observationAvailable: observationAvailable, bar: state.observed.onBar, displayName: displayName, units: units) { return true }
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
                NSLog("[Sommelier] arrange env move: %@ -> %@ movable index %@", "\(key)", section.rawValue, index.map(String.init) ?? "-")
                // Same clamp as a UI drop; the index is 0-based among movable items (modules do not count).
                let outcome = ArrangeDrop.drop(layout: self.layout, key: key, section: section, movableIndex: index,
                                               capabilities: self.cap, observationAvailable: self.observationAvailable,
                                               bar: self.state.observed.onBar, displayName: self.displayName, units: self.units)
                _ = self.submit(outcome, key: key)
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
            var track: [ItemKey] = []
            message = willNotFit ? "Dropped left of the overflow boundary: macOS will keep it behind the chevron." : nil
            for k in moved {
                let was = old.section(of: k), now = l.section(of: k)
                if was == now, now != .visible { continue }   // pure reorder inside a hidden strip: our data, nothing to verify
                track.append(k)
            }
            NSLog("[Sommelier] arrange: submit layout; moved=%@", moved.map { "\($0)" }.joined(separator: ", "))
            apply(l, tracking: track, basedOn: state.layoutRevision)
            return true
        }
    }

    /// Submits `l`. `tracking`: keys the window now waits for; they are judged only by passes started after the revision the
    /// engine stamps on `l` (the stamp arrives with `setLayout`'s return).
    /// `basedOn`: the layout revision `l` was composed on (gdu.52); the engine re-adds items it appended after it. A drop composes
    /// and submits in the same main-actor turn, so it passes the current revision; a confirm dialog passes the revision from when it opened.
    private func apply(_ l: ArrangeLayout, tracking: [ItemKey] = [], basedOn base: Int) {
        guard let engine = model.engine else { message = "The layout engine is not running."; return }
        let ticket = tracker.record(tracking, passesStarted: state.passesStarted, now: Date(), awaitingStamp: true)
        pending.submit(l)
        ensureTimer()
        Task { [weak self] in   // never block the main actor on the engine
            let stamp = await engine.setLayout(l, basedOn: base)
            self?.published(stamp, ticket: ticket)
        }
    }

    private func published(_ stamp: LayoutRevision, ticket: Int) {
        tracker.stamp(ticket: ticket, passesStartedAtRevision: stamp.passesStarted)
        pending.submitted(revision: stamp.revision)
        pending.resolve(stateRevision: state.layoutRevision)
    }

    // MARK: toolbar and menu actions

    func reapply() {
        guard let engine = model.engine else { return }
        tracker.retry(passesStarted: state.passesStarted, now: Date())
        Task { await engine.clearFailures(); await engine.requestReconcile() }
    }

    func retry(_ key: ItemKey) {
        guard let engine = model.engine else { return }
        tracker.retry(passesStarted: state.passesStarted, now: Date())
        Task { await engine.clearFailures(); await engine.requestReconcile() }
    }

    func askAdopt() { confirm = .adopt(ArrangeDrop.adopt(observed: state.observed, current: layout, units: units), base: state.layoutRevision) }

    func askHideNotFitting() {
        let r = ArrangeDrop.hideNotFitting(layout: layout, observed: state.observed, capabilities: cap, units: units)
        let c = content
        func t(_ k: ItemKey) -> String { (c.visible.rows + c.hidden.rows + c.alwaysHidden.rows).first { $0.key == k }?.title ?? ArrangeSections.fallbackTitle(k) }
        confirm = .hideNotFitting(r.layout, titles: r.moved.map(t), blocked: r.blocked.map(t), base: state.layoutRevision)
    }

    func confirmed(_ c: Confirm) {
        confirm = nil
        switch c {
        case .adopt(let l, let base):
            NSLog("[Sommelier] arrange: adopt current order")
            tracker.removeAll()
            apply(l, basedOn: base)
        case .hideNotFitting(let l, let titles, _, let base):
            NSLog("[Sommelier] arrange: hide what does not fit: %@", titles.joined(separator: ", "))
            let old = layout
            apply(l, tracking: l.hidden.filter { old.section(of: $0) == .visible }, basedOn: base)
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
