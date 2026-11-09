@testable import DecisionCore

/// Swift-side name tables, written by hand and NOT using `Codec`: they render Swift values exactly as `Ffi.lean`'s `name…` functions render Lean values,
/// so a code swapped in the Swift decoder or encoder shows up as a different name.
enum Names {
    static func list(_ l: [Key]) -> String { "[" + l.map(String.init).joined(separator: ",") + "]" }
    static func rel(_ r: Rel) -> String {
        switch r { case .before(let t): return "before \(t)"; case .after(let t): return "after \(t)" }
    }
    static func actions(_ a: [Action]) -> String { a.map { "\($0.subject) \(rel($0.rel)) strip=\($0.strip) user=\($0.user)" }.joined(separator: " | ") }
    static func why(_ w: Why) -> String { switch w { case .stopped: return "stopped"; case .barFull: return "barFull"; case .plain: return "plain" } }
    static func status(_ s: Status) -> String {
        switch s {
        case .moving: return "moving"
        case .matches: return "matches"
        case .matchesExcept(let u): return "matchesExcept" + list(u)
        case .differs(let w): return "differs(\(why(w)))"
        case .checking: return "checking"
        }
    }
    static func verdict(_ v: Verdict) -> String {
        switch v {
        case .matches: return "matches"
        case .matchesExcept(let u): return "matchesExcept" + list(u)
        case .differs: return "differs"
        case .cannotTell: return "cannotTell"
        }
    }
    static func row(_ r: Row) -> String {
        switch r {
        case .moving: return "moving"; case .waiting: return "waiting"; case .tick: return "tick"; case .behind: return "behind"
        case .notWherePut: return "notWherePut"; case .notOnBar: return "notOnBar"; case .cannotTell: return "cannotTell"
        }
    }
    static func rowVerdict(_ v: RowVerdict) -> String {
        switch v {
        case .inOrder: return "inOrder"; case .behindChevron: return "behindChevron"; case .behindOutOfTurn: return "behindOutOfTurn"
        case .notOnBar: return "notOnBar"; case .outOfPlace: return "outOfPlace"; case .cannotTell: return "cannotTell"
        }
    }
    static func outcome(_ o: Outcome) -> String {
        switch o { case .verified: return "verified"; case .failed: return "failed"; case .refused: return "refused"; case .busy: return "busy" }
    }
    static func read(_ r: Read) -> String {
        let kind = r.kind == .pass ? "pass" : "poll"
        let chev: String; switch r.chevron { case .fresh: chev = "fresh"; case .stale: chev = "stale"; case .absent: chev = "absent" }
        let lvl: String; switch r.level { case .complete: lvl = "complete"; case .exceptSelfPositioning: lvl = "exceptSelfPositioning"; case .incomplete: lvl = "incomplete" }
        return "read(kind=\(kind) chevron=\(chev) level=\(lvl) settled=\(r.settled) stripOpen=\(r.stripOpen) observed=\(r.observed) notFullProven=\(r.notFullProven) drawn=\(list(r.drawn)) pile=\(list(r.pile)) folded=\(list(r.folded)) trusted=\(list(r.trusted)) nearFold=\(list(r.nearFold)) unread=\(list(r.unread)))"
    }
    static func event(_ e: Event) -> String {
        switch e {
        case .read(let r): return read(r)
        case .userEdit(let rec, let mv): return "userEdit(record=\(list(rec)) moved=\(list(mv)))"
        case .userRetry: return "userRetry"
        case .retryKey(let k): return "retryKey(\(k))"
        case .moveResult(let k, let o, let p): return "moveResult(\(k) \(outcome(o)) posted=\(p))"
        case .passBoundary: return "passBoundary"
        }
    }
}
