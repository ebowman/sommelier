import Foundation
import DecisionCore

/// One line of the audit trace of the core-driven order path (tests and the log; recorded only when `LayoutEngine.Config.recordCoreTrace`).
public enum CoreTraceEntry: Equatable, Sendable {
    /// An event sent to `DecisionCore.step`, by name (and the call site that sent it).
    case event(String, site: String)
    /// The core emitted an order move.
    case emitted(subject: ItemKey, relation: Relation, strip: Bool, user: Bool)
    /// The `moveResult` the engine sent for the emitted action (exactly one per `emitted`).
    case result(subject: ItemKey, outcome: Outcome, posted: Bool, site: String)
    /// A step failed (`DecisionError`).
    case error(String)
}

/// The engine's single serial owner of the proved core's state, its key interner and the bookkeeping that proves every emitted action
/// is answered by exactly one `moveResult` (wiring plan sections 1, 2, 5). A value type owned by the `LayoutEngine` actor: every call
/// runs on that actor, never in a `publish` closure on the main actor.
struct CoreDriver {
    private(set) var state: DecisionState?
    var keys = CoreKeys()
    /// The record as the core has it (interned, in record order).
    var record: [Key] = []
    /// Set by a failed step, cleared by the next successful one. While set, no order move is actuated.
    private(set) var down: DecisionError?
    /// The emitted action that still awaits its `moveResult`.
    private(set) var awaiting: (action: Action, subject: ItemKey)?
    /// ejb.21: the real answer (outcome, posted) of a `moveResult` step that threw while the action awaited. The end-of-pass net replays it
    /// instead of a made-up busy/not-posted; nil when no real answer was ever obtained.
    private(set) var awaitingRealAnswer: (outcome: Outcome, posted: Bool)?
    private(set) var emitted = 0
    private(set) var resolved = 0
    /// An action emitted while another still awaited its result, a result with nothing awaiting, or a result for another subject.
    private(set) var violations = 0
    var trace: [CoreTraceEntry]?
    /// TESTS ONLY: when set, every step fails with this error (the previous state is kept), as a `DecisionError` would.
    var injectedFailure: DecisionError?
    /// TESTS ONLY: with `injectedFailure`, fail only `moveResult` steps.
    var injectOnMoveResultOnly = false
    /// Wall time of the `.read` steps (the decision), for the timing report: count, total and worst, in nanoseconds.
    private(set) var readSteps = 0
    private(set) var readStepNanos: Int64 = 0
    private(set) var readStepWorstNanos: Int64 = 0
    /// Wall time of `ReadAdapter.adapt` (called once per fed read), same units.
    private(set) var adaptCount = 0
    private(set) var adaptNanos: Int64 = 0
    private(set) var adaptWorstNanos: Int64 = 0
    mutating func noteAdapt(_ ns: Int64) { adaptCount += 1; adaptNanos += ns; adaptWorstNanos = max(adaptWorstNanos, ns) }
    /// Pile of the previous COMPLETE read (raw), for the adapter's settledness rule.
    var lastCompletePile: Set<ItemKey>?
    /// The last `Read` fed, for the next row/status computation (Wiring 4) and the timing test.
    private(set) var lastRead: Read?
    /// ejb.16: the last PASS read, and what the core says of it. Changed only by a pass read, or by a non-read event judged against the last pass
    /// read; a poll read is fed to the core but never touches either (no flicker between matches and matches-except).
    private(set) var lastPassRead: Read?
    private(set) var display: CoreDisplay?
    /// Set when the status/rows query itself failed (the step did not): the display is then nil and the engine shows `lastError`.
    private(set) var displayError: DecisionError?
    /// A non-read event changed the state after the last pass read: the display is stale until `settleDisplay()` (computed only where it can be published).
    private var displayDirtyState: DecisionState?

    var isDown: Bool { down != nil }

    mutating func note(_ e: CoreTraceEntry) { trace?.append(e) }

    /// The state, created on first use. A creation failure leaves the driver down.
    private mutating func ensureState() -> DecisionState? {
        if let s = state { return s }
        do { let s = try DecisionState(record: []); state = s; return s }
        catch { down = error; return nil }
    }

    /// `DecisionCore.step`. A failure keeps the previous state, marks the driver down and returns the error; the next success clears it.
    /// The action (at most one) is registered as awaiting its result.
    mutating func step(_ e: Event, name: String, site: String) -> Result<[Action], DecisionError> {
        guard let s = ensureState() else { note(.error("no state")); return .failure(down ?? .runtimeUnavailable) }
        note(.event(name, site: site))
        do throws(DecisionError) {
            let t0 = ContinuousClock.now
            // TESTS ONLY: fails exactly where a real `DecisionCore.step` would throw (after the event is named, before the state changes)
            if let f = injectedFailure, !injectOnMoveResultOnly || { if case .moveResult = e { return true } else { return false } }() { throw f }
            let (n, actions) = try DecisionCore.step(s, e)
            if case .read = e {
                let d = t0.duration(to: .now).components
                let ns = d.seconds * 1_000_000_000 + d.attoseconds / 1_000_000_000
                readSteps += 1; readStepNanos += ns; readStepWorstNanos = max(readStepWorstNanos, ns)
            }
            state = n
            down = nil
            if case .read(let r) = e { lastRead = r }
            switch e {
            case .read(let r): if r.kind == .pass { lastPassRead = r; displayDirtyState = nil; refreshDisplay(s, r) }   // the pair the step judged: (state before, read)
            default:
                if case .userEdit(let rec, _) = e { record = rec }   // the rows of THIS event cover the new record, not the previous one
                if lastPassRead != nil { displayDirtyState = n }   // not computed here: only a pass read and `settleDisplay()` (end of pass) compute
            }
            if case .moveResult(let k, let o, let posted) = e {
                // the one answer to the awaiting action, counted only once the core has it (a failed step leaves the action awaiting,
                // so the end-of-pass safety net or the next attempt still answers it, exactly once overall)
                if let w = awaiting { if w.action.subject != k { violations += 1 }; awaiting = nil; awaitingRealAnswer = nil; resolved += 1; note(.result(subject: w.subject, outcome: o, posted: posted, site: site)) }
                else { violations += 1 }
            }
            if let a = actions.first, let subject = keys.key(for: a.subject) {
                if awaiting != nil { violations += 1 }
                awaiting = (a, subject); awaitingRealAnswer = nil
                emitted += 1
                let rel: Relation
                switch a.rel {
                case .before(let t): rel = keys.key(for: t).map { .before($0) } ?? .leftmost
                case .after(let t): rel = keys.key(for: t).map { .after($0) } ?? .leftmost
                }
                note(.emitted(subject: subject, relation: rel, strip: a.strip, user: a.user))
            } else if let a = actions.first {
                // an Action naming a key this engine never interned: cannot be performed; answered by the caller as failed/not posted
                if awaiting != nil { violations += 1 }
                awaiting = (a, ItemKey.module(name: "?unmapped")); awaitingRealAnswer = nil
                emitted += 1
            }
            return .success(actions)
        } catch {
            down = error
            if case .moveResult(_, let o, let posted) = e, awaiting != nil { awaitingRealAnswer = (o, posted) }   // ejb.21: keep the real answer for the net
            note(.error("\(error)"))
            return .failure(error)
        }
    }

    /// Computes the display a non-read event left stale (once, however many events changed it). Call only where the result can be published.
    mutating func settleDisplay() {
        guard let n = displayDirtyState, let r = lastPassRead else { return }
        displayDirtyState = nil
        refreshDisplay(n, r)
    }

    /// The core's status and rows for (state, read). A failure leaves no display and records the error; never a default.
    private mutating func refreshDisplay(_ s: DecisionState, _ r: Read) {
        do throws(DecisionError) {
            let status = try DecisionCore.status(s, r)
            var rows: [ItemKey: Row] = [:], notes: [ItemKey: RowNote] = [:]
            for id in record {
                guard let k = keys.key(for: id) else { continue }
                rows[k] = try DecisionCore.row(s, r, id)
                if let n = try DecisionCore.rowNote(s, r, id) { notes[k] = n }
            }
            // ejb.20 (Lean `rowReapply`): the status says the engine's planned move of one key waits for Re-apply; that key's row says so beside its mark when the mark is "not where you put it"
            var reapplyKey: ItemKey?
            if case .differs(.needsReapply(let id)) = status, let k = keys.key(for: id) {
                reapplyKey = k
                if rows[k] == .notWherePut { notes[k] = .needsReapply }
            }
            let adoption = CoreAdoption.proposal(state: s, read: r, keys: keys)   // ejb.9: asked of the same (state, read) pair as the status; a failed call is "no proposal" (the button stays off), never a default record
            display = CoreDisplay(status: status, rows: rows, notes: notes, pileCount: r.pile.count, reapplyKey: reapplyKey, adoption: adoption)
            displayError = nil
        } catch {
            display = nil
            displayError = error
            note(.error("display: \(error)"))
        }
    }

    /// Core key -> engine key for a performed action; nil when the id was never handed out or names the chevron.
    func relation(_ a: Action) -> (subject: ItemKey, relation: Relation)? {
        guard let s = keys.key(for: a.subject) else { return nil }
        switch a.rel {
        case .before(let t): return keys.key(for: t).map { (s, .before($0)) }
        case .after(let t): return keys.key(for: t).map { (s, .after($0)) }
        }
    }
}
