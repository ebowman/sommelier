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
            if case .moveResult(let k, let o, let posted) = e {
                // the one answer to the awaiting action, counted only once the core has it (a failed step leaves the action awaiting,
                // so the end-of-pass safety net or the next attempt still answers it, exactly once overall)
                if let w = awaiting { if w.action.subject != k { violations += 1 }; awaiting = nil; resolved += 1; note(.result(subject: w.subject, outcome: o, posted: posted, site: site)) }
                else { violations += 1 }
            }
            if let a = actions.first, let subject = keys.key(for: a.subject) {
                if awaiting != nil { violations += 1 }
                awaiting = (a, subject)
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
                awaiting = (a, ItemKey.module(name: "?unmapped"))
                emitted += 1
            }
            return .success(actions)
        } catch {
            down = error
            note(.error("\(error)"))
            return .failure(error)
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
