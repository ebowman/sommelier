import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import SommelierCore

/// Drag payload: the item's store key as plain text (a ghost capsule's drag carries the "#ghost" suffix, like `ArrangeRow.id`).
struct ArrangePayload: Transferable, Equatable {
    var storeKey: String
    var fromGhost = false
    init(storeKey: String, fromGhost: Bool = false) { self.storeKey = storeKey; self.fromGhost = fromGhost }
    static let ghostSuffix = "#ghost"
    /// The wire text: `storeKey`, plus the ghost suffix.
    var text: String { fromGhost ? storeKey + Self.ghostSuffix : storeKey }
    init(text: String) {
        if text.hasSuffix(Self.ghostSuffix) { self.init(storeKey: String(text.dropLast(Self.ghostSuffix.count)), fromGhost: true) }
        else { self.init(storeKey: text) }
    }
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.text }, importing: { ArrangePayload(text: $0) })
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
    /// UI-only: the transient callout for the last refused drop (cleared by the tick after `RefusalCallout.duration`).
    private(set) var refusal: RefusalCallout?
    var confirm: Confirm?
    /// ejb.9: the "Use the bar's current order" sheet (what Save would change). Own sheet, not a `Confirm`: it lists the change.
    var barOrderSheet: BarOrderSheet?
    struct BarOrderSheet: Identifiable {
        var preview: CoreAdoption.Preview
        /// The engine layout revision the preview was composed on, passed as `setLayout(basedOn:)`.
        var base: Int
        /// "Title: position a -> position b" for every key whose place in Visible changes.
        var lines: [String]
        var id: Int { base }
    }
    /// 9o9.4: ids of the drop targets a drag is hovering; non-empty = an Arrange drag is in flight (the engine makes no actuator call).
    @ObservationIgnored private var dragTargets: Set<String> = []
    func dragTargeting(_ id: String, _ on: Bool) {
        let was = !dragTargets.isEmpty
        if on { dragTargets.insert(id) } else { dragTargets.remove(id) }
        if was != !dragTargets.isEmpty { model.arrangeDragChanged(!dragTargets.isEmpty) }
    }
    /// Slot currently targeted by a drag, for the insertion indicator.
    var hoverSlot: (section: LayoutSection, slot: Int)?
    /// The waiting state machine (pure, in SommelierCore); this class only feeds it.
    /// gdu.117: stored out of band so a quiet tick (`update` rewrites its bookkeeping every 250 ms) does not invalidate the view;
    /// observers are notified only when `renderState` changes (see `editTracker`).
    @ObservationIgnored private var trackerStore = ArrangeTracker()
    private(set) var tracker: ArrangeTracker {
        get { access(keyPath: \.tracker); return trackerStore }
        set { withMutation(keyPath: \.tracker) { trackerStore = newValue } }
    }
    @discardableResult
    private func editTracker<R>(_ edit: (inout ArrangeTracker) -> R) -> R {
        var t = trackerStore
        let before = t.renderState
        let r = edit(&t)
        if t.renderState != before { tracker = t } else { trackerStore = t }
        return r
    }
    /// gdu.102: `drop#<n>` ids, one per gesture (drop, step, menu move, env move); resets per launch.
    @ObservationIgnored private var dropCounter = 0
    private func nextDropID() -> Int { dropCounter += 1; return dropCounter }
    /// The layout we submitted until the engine has published it (by revision, gdu.48); rapid consecutive drops build on it.
    private(set) var pending = PendingLayout()
    /// Capability rules derived from `state.items`; refreshed on demand (see `cap`), never only while the window is open.
    @ObservationIgnored private var capabilities: CapabilityRules
    @ObservationIgnored private var capPass = -1
    @ObservationIgnored private var capItems = -1
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var windowVisible = false
    /// Floats the Arrange window while the engine drags and takes activation back afterwards (gdu.100).
    @ObservationIgnored private var windowGuard = ArrangeWindowGuard()
    @ObservationIgnored var onWindowCommand: ((ArrangeWindowGuard.Command) -> Void)?
    /// gdu.136: the window's real state for the guard: on screen (open, not miniaturized), unoccluded, key.
    @ObservationIgnored var windowProbe: (() -> (onScreen: Bool, unoccluded: Bool, key: Bool))?
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private var loggedGeneration = -1
    /// gdu.117 live counters: `ArrangeView.body` evaluations and `ArrangeSections.make` runs. Logged (`arrange: renders=...`) at most once
    /// a second and only when they moved, so an idle window writes nothing.
    @ObservationIgnored var renderCount = 0
    @ObservationIgnored private(set) var contentBuilds = 0
    @ObservationIgnored private var loggedCounts = (0, 0)
    @ObservationIgnored private var lastCountLog = Date.distantPast
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
    /// gdu.87: macOS denies the Control Center store read (App Data privacy): the Arrange window links to the permissions pane.
    var controlCenterDataDenied: Bool { model.permissions.controlCenterData == .denied }
    func showPermissions() { model.showOnboarding() }
    var observationAvailable: Bool { !state.observed.onBar.isEmpty && observationProblem == nil }

    @ObservationIgnored private var appNames = AppNameCache(lookup: HideUnitNames.runningAppName)
    @ObservationIgnored private var appNamesPass = -1
    /// Per-pass memo of running-app names: the LaunchServices lookup is an XPC round trip (gdu.93).
    private func unitAppName(_ bundleID: String) -> String? {
        if state.passCount != appNamesPass { appNames.invalidate(); appNamesPass = state.passCount }
        return appNames.name(for: bundleID)
    }

    /// gdu.117: bumped (and observers notified) when an input the cached `content` read changes; SwiftUI re-reads `content` then.
    private var contentRevision = 0
    @ObservationIgnored private var cachedContent: ArrangeContent?
    @ObservationIgnored private var contentDirty = true
    /// Counts rebuilds; equal values mean `content` is the same cached instance (the rows log and tests use it).
    @ObservationIgnored private(set) var contentGeneration = 0

    /// The rows, memoized: rebuilt only after an observable input it read (engine state, layout, pending, tracker, filter, ...) was
    /// written, tracked with `withObservationTracking` so no input can be forgotten. A tick that changes nothing never rebuilds it.
    var content: ArrangeContent {
        _ = contentRevision   // the view's dependency; the inputs themselves are tracked by the builder below
        if let c = cachedContent, !contentDirty { return c }
        var built: ArrangeContent?
        withObservationTracking {
            built = buildContent()
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.contentInvalidated() }
        }
        contentDirty = false
        contentBuilds += 1; contentGeneration += 1
        cachedContent = built
        return built!
    }

    private func contentInvalidated() {
        guard !contentDirty else { return }
        contentDirty = true
        contentRevision &+= 1
    }

    private func buildContent() -> ArrangeContent {
        ArrangeSections.make(observed: state.observed, layout: layout, items: state.items, perItem: state.perItem,
                             capabilities: cap, showHiddenSection: state.showHiddenSection,
                             awaiting: tracker.awaiting, timedOut: tracker.timedOut,
                             suppressedStatus: tracker.suppressed(passSequence: state.passSequence, observationSettled: state.observationSettled,
                                                  planPass: state.lastPlan.passStarted),
                             pendingConfirmation: state.pendingConfirmation, unverifiedAfterHandDrag: state.unverifiedAfterHandDrag,
                             coreRows: state.coreRows, coreNotes: state.coreNotes,
                             observationProblem: observationProblem, filter: filter, units: units,
                             unitAppName: { [self] in self.unitAppName($0) }, moveReasons: state.inFlight != nil ? state.orderMoveReasons : [:])
    }

    var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }
    var hasNotFitting: Bool { !state.observed.systemOverflow.isEmpty || !state.observed.foldedParked.isEmpty }
    /// ejb.16 (D10): the same text the menu shows, from the core's status through the one renderer.
    var statusText: String {
        CoreStatusText.text(state: state, trusted: model.trusted, conflicting: model.conflictingManager)
    }
    private static func subject(of a: PlannedAction) -> ItemKey {
        switch a { case .move(let k, _), .hide(let k), .show(let k): return k }
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

    func stop() {
        windowVisible = false
        driveWindowGuard()
    }

    private func driveWindowGuard() {
        let probe = windowProbe?() ?? (onScreen: windowVisible, unoccluded: windowVisible, key: false)
        if let cmd = windowGuard.update(inFlight: state.inFlight != nil, windowVisible: windowVisible && probe.unoccluded, appActive: NSApp.isActive,
                                        windowKey: probe.key, windowOnScreen: windowVisible && probe.onScreen, now: Date()) {
            onWindowCommand?(cmd)
        }
    }

    /// The 250 ms tick runs only while it has a job: window visible, a drop awaited / pending, a callout showing, or the engine dragging.
    /// It is restarted by `start`, `apply` and a refused drop's callout.
    private func ensureTimer() {
        guard timer == nil else { return }
        // Common run loop modes: the tick (rows log, pause expiry, stall detector) keeps running during drag tracking (gdu.93).
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refreshCapabilities(force: Bool = false) {
        guard force || state.passCount != capPass || state.items.count != capItems else { return }
        capPass = state.passCount; capItems = state.items.count
        capabilities = ArrangeCapabilities.rules(items: state.items, resolver: EngineFactory.currentTrackedResolver())
    }

    private func stopTimerIfIdle() {
        guard !windowVisible, trackerStore.isEmpty, !pending.isActive, refusal == nil, state.inFlight == nil else { return }
        timer?.invalidate(); timer = nil; lastTick = nil
    }

    func tick() {
        let t = Date()
        if let last = lastTick, t.timeIntervalSince(last) - 0.25 > 0.1 {
            AppLog.log(.arrange, "arrange: MAIN ACTOR STALL: timer \(String(format: "%.0f", (t.timeIntervalSince(last) - 0.25) * 1000)) ms late")
        }
        lastTick = t
        // The pause text hides itself when its window ends (gdu.60): `statusText` re-reads the clock, this makes the view re-render.
        if let until = state.pollSuppression?.until, until <= t, windowVisible { state.pollSuppression = nil }
        driveWindowGuard()
        if let r = refusal, !r.isActive(at: t) { refusal = nil }
        guard windowVisible || !trackerStore.isEmpty || pending.isActive || refusal != nil else { stopTimerIfIdle(); return }
        refreshCapabilities()
        // Write the observed `pending` only when it actually resolves (an assignment invalidates the view even when equal).
        if pending.isActive { var p = pending; if p.resolve(stateRevision: state.layoutRevision) { pending = p } }
        guard !pending.isActive else { if windowVisible { logRowsIfChanged() }; return }
        if !trackerStore.isEmpty {
            let lines: [String] = editTracker {
                $0.update(observed: state.observed, layout: layout, perItem: state.perItem, passSequence: state.passSequence,
                          showHiddenSection: state.showHiddenSection, now: t,
                          observationSettled: state.observationSettled, planPass: state.lastPlan.passStarted)
            }
            for line in lines { AppLog.log(.arrange, "arrange: \(line)") }
        }
        if windowVisible { logRowsIfChanged(); logCountsIfChanged(t) }
    }

    private func logCountsIfChanged(_ now: Date) {
        guard (renderCount, contentBuilds) != loggedCounts, now.timeIntervalSince(lastCountLog) >= 1 else { return }
        loggedCounts = (renderCount, contentBuilds); lastCountLog = now
        AppLog.log(.arrange, "arrange: renders=\(renderCount) contentBuilds=\(contentBuilds)")
    }

    /// One line per change of what the window shows (the "truth log" used for live verification).
    private func logRowsIfChanged() {
        let c = content
        guard loggedGeneration != contentGeneration else { return }
        loggedGeneration = contentGeneration
        func line(_ s: ArrangeStrip) -> String {
            s.rows.map { r in (r.isBoundary ? "|OVERFLOW|" : r.title + (r.isGhost ? "(ghost)" : "") + r.badge.glyph) }.joined(separator: " ")
        }
        let sig = "V[\(line(c.visible))] H[\(line(c.hidden))] A[\(line(c.alwaysHidden))]"
        guard sig != lastSignature else { return }
        lastSignature = sig
        AppLog.log(.arrange, "arrange rows: \(sig)  status=\(statusText)")
    }

    // MARK: gestures

    func drop(_ payloads: [ArrangePayload], section: LayoutSection, slot: Int) -> Bool {
        hoverSlot = nil
        if !dragTargets.isEmpty { dragTargets = []; model.arrangeDragChanged(false) }   // the drag ended in a drop
        guard !isFiltering, let p = payloads.first, let key = ItemKey(storeKey: p.storeKey) else { return false }
        let rows = content.strip(section).rows
        let outcome = ArrangeDrop.drop(layout: layout, rows: rows, slot: slot, key: key, section: section, capabilities: cap,
                                       observationAvailable: observationAvailable,
                                       bar: state.observed.onBar, displayName: displayName, units: units,
                                       parked: Set(state.observed.parked))
        let id = nextDropID()
        // gdu.116: every capsule carries the drag gesture; whether the SOURCE could be picked up is judged here.
        let c = content
        let all = c.visible.rows + c.hidden.rows + c.alwaysHidden.rows + c.visible.notRunning + c.hidden.notRunning + c.alwaysHidden.notRunning
        if let why = ArrangeDrop.sourceRefusal(key: key, fromGhost: p.fromGhost, rows: all) {
            AppLog.log(.arrange, "arrange: drop \(key) -> \(section.rawValue) slot \(slot) (source not draggable)")
            return submit(.rejected(why), key: key, dropID: id)
        }
        AppLog.log(.arrange, "arrange: drop \(key) -> \(section.rawValue) slot \(slot)")
        AppLog.log(.arrange, "arrange: " + DropTrace.intentLine(id: id, key: key, section: section, slot: slot, rows: rows, observed: state.observed,
                                                              settled: state.observationSettled, displayName: displayName))
        return submit(outcome, key: key, dropID: id, intent: section == .visible ? DropIntent.from(rows: rows, slot: slot, key: key) : nil)
    }

    func move(_ key: ItemKey, to section: LayoutSection) {
        _ = submit(ArrangeDrop.outcome(layout: layout, key: key, to: section, index: nil, capabilities: cap,
                                       observationAvailable: observationAvailable, units: units,
                                       parked: Set(state.observed.parked)), key: key, dropID: nextDropID())
    }

    /// Item name for refusal texts: the engine's `ItemInfo` when known, else the key.
    private var displayName: (ItemKey) -> String {
        { [namer = RowNameRule.Namer(layout: layout, items: state.items), items = state.items] k in items[k] != nil ? namer.name(k) : "\(k)" }
    }

    func canMove(_ key: ItemKey, to section: LayoutSection) -> Bool {
        // The menu reads the precomputed `ArrangeRow.movableTo`; this is the same rule (ArrangeDrop.canMove) for other callers.
        ArrangeDrop.canMove(layout: layout, key: key, to: section, capabilities: cap, observationAvailable: observationAvailable,
                            units: units, parked: Set(state.observed.parked))
    }

    func step(_ key: ItemKey, _ dir: ArrangeDrop.Direction) {
        _ = submit(ArrangeDrop.step(layout: layout, rows: content.visible.rows, key: key, dir, capabilities: cap,
                                    observationAvailable: observationAvailable, bar: state.observed.onBar, displayName: displayName, units: units), key: key, dropID: nextDropID())
    }

    func canStep(_ key: ItemKey, _ dir: ArrangeDrop.Direction, rows: [ArrangeRow]) -> Bool {
        if case .move = ArrangeDrop.step(layout: layout, rows: rows, key: key, dir, capabilities: cap,
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
                    AppLog.log(.arrange, "arrange env move: bad spec \(one)"); continue
                }
                let section: LayoutSection? = ["visible": .visible, "hidden": .hidden, "always": .alwaysHidden, "alwaysHidden": .alwaysHidden][parts[parts.count - 2]]
                let index = Int(parts[parts.count - 1])
                guard let section else { AppLog.log(.arrange, "arrange env move: bad section in \(one)"); continue }
                self.ensureTimer()
                let id = self.nextDropID()
                AppLog.log(.arrange, "arrange env move: \(DropTrace.tag(id)) \(key) -> \(section.rawValue) movable index \(index.map(String.init) ?? "-")")
                // Same clamp as a UI drop; the index is 0-based among movable items (modules do not count).
                let outcome = ArrangeDrop.drop(layout: self.layout, key: key, section: section, movableIndex: index,
                                               capabilities: self.cap, observationAvailable: self.observationAvailable,
                                               bar: self.state.observed.onBar, displayName: self.displayName, units: self.units, parked: Set(self.state.observed.parked))
                _ = self.submit(outcome, key: key, dropID: id)
                if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
            }
        }
    }

    @discardableResult
    private func submit(_ outcome: ArrangeDrop.Outcome, key: ItemKey, dropID: Int? = nil, intent: DropIntent? = nil) -> Bool {
        var outcome = outcome
        // 9o9.3: while the upgrade adoption is pending a Visible drop needs the bar order to adopt first; without a clean read it is refused.
        if case .move(let l, _, _) = outcome, ArrangeDrop.adoptionRefusal(pending: state.layout.pendingAdoption, cleanObservation: state.cleanObservationAvailable,
                                                                           current: state.layout, proposed: l) {
            outcome = .rejected(ArrangeDrop.readingOrder)
        }
        switch outcome {
        case .noop:
            message = nil
            AppLog.log(.arrange, "arrange: \(key) dropped on its own position: no change")
            if let dropID { AppLog.log(.arrange, "arrange: " + DropTrace.doneLine(id: dropID, outcome: "noop")) }
            return true
        case .rejected(let why):
            message = why
            let c = content
            if RefusalCallout.anchor(for: key, in: c.visible.rows + c.hidden.rows + c.alwaysHidden.rows + c.visible.notRunning + c.hidden.notRunning + c.alwaysHidden.notRunning) != nil {
                refusal = RefusalCallout.show(refusal, key: key, why: why, now: Date())
                AppLog.log(.arrange, "arrange: callout at \(key): \(why)")
                ensureTimer()
            }
            AppLog.log(.arrange, "arrange: rejected \(key): \(why)")
            if let dropID {
                AppLog.log(.arrange, "arrange: " + DropTrace.rejectedLine(id: dropID, why: why))
                AppLog.log(.arrange, "arrange: " + DropTrace.doneLine(id: dropID, outcome: "rejected"))
            }
            return false
        case .move(let l, let moved, let willNotFit):
            let old = layout
            var track: [ItemKey] = []
            // gdu.144 rule 5 / D6: a Visible drop left of the fold line says macOS folds from the left. A FOLDED key stays behind «; a DRAWN key is in the
            // record and goes as far left as the drawn items go. Also with a stale chevron (`hasChevron`).
            let o = state.observed
            let chevronBar = o.hasChevron
            let wasFolded = o.systemOverflow.union(o.foldedParked).contains(key)
            message = willNotFit && chevronBar ? (wasFolded ? ArrangeBarState.stayBehindText(displayName(key)) : ArrangeBarState.cannotGoFurtherLeftText(displayName(key))) : nil
            track = keysToTrack(moved: moved, old: old, new: l)   // hidden-strip reorders are not tracked
            AppLog.log(.arrange, "arrange: submit layout; moved=\(moved.map { "\($0)" }.joined(separator: ", "))")
            if let dropID { AppLog.log(.arrange, "arrange: " + DropTrace.layoutLine(id: dropID, key: key, layout: l)) }
            apply(l, tracking: track, basedOn: state.layoutRevision, moved: Set(moved), dropID: dropID, intent: intent)
            return true
        }
    }

    /// Submits `l`. `tracking`: keys the window now waits for; they are judged only by passes started after the revision the
    /// engine stamps on `l` (the stamp arrives with `setLayout`'s return).
    /// `basedOn`: the layout revision `l` was composed on (gdu.52); the engine re-adds items it appended after it. A drop composes
    /// and submits in the same main-actor turn, so it passes the current revision; a confirm dialog passes the revision from when it opened.
    private func apply(_ l: ArrangeLayout, tracking: [ItemKey] = [], basedOn base: Int, moved: Set<ItemKey> = [], dropID: Int? = nil, intent: DropIntent? = nil) {
        guard let engine = model.engine else { message = "The layout engine is not running."; return }
        let ticket = editTracker { $0.record(tracking, passesStarted: state.passesStarted, now: Date(), awaitingStamp: true, dropID: dropID, intent: intent) }
        pending.submit(l)
        ensureTimer()
        Task { [weak self] in   // never block the main actor on the engine
            let stamp = await engine.setLayout(l, basedOn: base, moved: moved)
            self?.published(stamp, ticket: ticket)
        }
    }

    private func published(_ stamp: LayoutRevision, ticket: Int) {
        editTracker { $0.stamp(ticket: ticket, passesStartedAtRevision: stamp.passesStarted) }
        pending.submitted(revision: stamp.revision)
        pending.resolve(stateRevision: state.layoutRevision)
    }

    // MARK: toolbar and menu actions

    func reapply() {
        guard let engine = model.engine else { return }
        editTracker { $0.retry(passesStarted: state.passesStarted, now: Date()) }
        Task { await engine.userRetry(); await engine.requestReconcile() }   // gdu.144 D4: the user's Retry (gives the budget and the hold back)
    }

    /// "Try again" on one row: clears the engine's give-up / failure history of `key` and plans it again (`LayoutEngine.retry(key:)`).
    func retry(_ key: ItemKey) {
        guard let engine = model.engine else { return }
        editTracker { $0.retry(passesStarted: state.passesStarted, now: Date()) }
        Task { await engine.retry(key: key) }
    }

    func askAdopt() { confirm = .adopt(ArrangeDrop.adopt(observed: state.observed, current: layout, units: units), base: state.layoutRevision) }

    /// ejb.9: what "Use the bar's current order" would save, or nil (the button is off). Lean decides (`adoptProposal`); the proposal rides on the core's display.
    var barOrderPreview: CoreAdoption.Preview? { CoreAdoption.preview(proposal: state.coreDisplay?.adoption, layout: layout) }

    func askUseBarOrder() {
        guard let pv = barOrderPreview else { return }
        let c = content
        func t(_ k: ItemKey) -> String { (c.visible.rows + c.hidden.rows + c.alwaysHidden.rows + c.visible.notRunning + c.hidden.notRunning + c.alwaysHidden.notRunning).first { $0.key == k }?.title ?? ArrangeSections.fallbackTitle(k) }
        barOrderSheet = BarOrderSheet(preview: pv, base: state.layoutRevision,
                                      lines: pv.changes.map { "\(t($0.key)): \($0.from) \u{2192} \($0.to)" })
    }

    /// Save: the normal record-saving path (`setLayout`), a user edit that names no moved key, so no drag is owed: the record becomes the bar's own order.
    func saveBarOrder(_ s: BarOrderSheet) {
        barOrderSheet = nil
        AppLog.log(.arrange, "arrange: use the bar's current order; \(s.preview.changes.count) item(s) change place")
        editTracker { $0.removeAll() }
        apply(s.preview.layout, basedOn: s.base)
    }

    func askHideNotFitting() {
        let r = ArrangeDrop.hideNotFitting(layout: layout, observed: state.observed, capabilities: cap, units: units)
        let c = content
        func t(_ k: ItemKey) -> String { (c.visible.rows + c.hidden.rows + c.alwaysHidden.rows + c.visible.notRunning + c.hidden.notRunning + c.alwaysHidden.notRunning).first { $0.key == k }?.title ?? ArrangeSections.fallbackTitle(k) }
        confirm = .hideNotFitting(r.layout, titles: r.moved.map(t), blocked: r.blocked.map(t), base: state.layoutRevision)
    }

    func confirmed(_ c: Confirm) {
        confirm = nil
        switch c {
        case .adopt(let l, let base):
            AppLog.log(.arrange, "arrange: adopt current order")
            editTracker { $0.removeAll() }
            apply(l, basedOn: base)
        case .hideNotFitting(let l, let titles, _, let base):
            AppLog.log(.arrange, "arrange: hide what does not fit: \(titles.joined(separator: ", "))")
            let old = layout
            apply(l, tracking: l.hidden.filter { old.section(of: $0) == .visible }, basedOn: base,
                  moved: Set(l.hidden.filter { old.section(of: $0) == .visible }))   // gdu.144 rule 6: the hidden keys are the edit's moved keys
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
