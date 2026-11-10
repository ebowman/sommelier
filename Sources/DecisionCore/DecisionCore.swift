import LeanCore

/// An immutable, persistent state of the PROVED Lean decision core (Lean `Sommelier.State`), owned through an opaque handle that is
/// released in `deinit`.
///
/// Threading rules (see also docs/verified-core.md):
/// * The Lean runtime is initialised exactly once per process (`pthread_once` in the C shim), by whichever call comes first.
/// * Every OTHER thread that calls into the core is initialised on its first call, and finalised when the thread exits. Callers do
///   nothing: there is no per-thread setup to forget.
/// * Every state is marked multithreaded when created (atomic reference counts), so one state may be read, stepped and released from
///   any threads at the same time. `step` never mutates its input: it returns a NEW state, so two threads stepping the same state
///   each get their own result. Nothing here takes a lock; ordering of events is the caller's job (one serial owner of the
///   "current" state, as the engine will have).
public final class DecisionState: @unchecked Sendable {
    let handle: OpaquePointer

    /// A fresh state for `record`, the order the user wants.
    public init(record: [Key]) throws(DecisionError) {
        let h = record.withUnsafeBufferPointer { sm_init($0.baseAddress, $0.count) }
        guard let h else { throw .runtimeUnavailable }
        handle = h
    }

    init(adopting h: OpaquePointer) { handle = h }

    deinit { sm_release(handle) }
}

/// The decision core: pure functions of a state and an input. No I/O, clock, AX, logging or Foundation in this module.
/// Each call checks the Lean side decoded its input (a malformed input throws `.malformedInput`, never a default value).
public enum DecisionCore {
    /// `step : State -> Event -> State × List Action`. Throws, and has no effect, on a malformed event.
    public static func step(_ state: DecisionState, _ event: Event) throws(DecisionError) -> (DecisionState, [Action]) {
        let (s, payload) = try Raw.step(state, Codec.encode(event))
        guard let actions = Codec.actions(payload) else { throw .undecodableOutput }
        return (s, actions)
    }

    /// Fold `step` over events; all actions in order (Lean `run`).
    public static func run(_ state: DecisionState, _ events: [Event]) throws(DecisionError) -> (DecisionState, [Action]) {
        var s = state; var all: [Action] = []
        for e in events { let (n, a) = try step(s, e); s = n; all += a }
        return (s, all)
    }

    /// `statusLine s r`
    public static func status(_ state: DecisionState, _ read: Read) throws(DecisionError) -> Status {
        guard let v = Codec.status(try Raw.query(.status, state, Codec.encode(read))) else { throw .undecodableOutput }
        return v
    }

    /// `shownVerdict s r`
    public static func shownVerdict(_ state: DecisionState, _ read: Read) throws(DecisionError) -> Verdict {
        guard let v = Codec.verdict(try Raw.query(.shownVerdict, state, Codec.encode(read))) else { throw .undecodableOutput }
        return v
    }

    /// `rowLine s r k`
    public static func row(_ state: DecisionState, _ read: Read, _ key: Key) throws(DecisionError) -> Row {
        guard let v = Codec.row(try Raw.query(.rowLine, state, Codec.encode(read), key: [key])) else { throw .undecodableOutput }
        return v
    }

    /// `rowNote s r k`: the note beside the row (`nil` = no note). Throws `.malformedInput` for a malformed read or key and
    /// `.undecodableOutput` for an answer that is not a note code.
    public static func rowNote(_ state: DecisionState, _ read: Read, _ key: Key) throws(DecisionError) -> RowNote? {
        guard let v = Codec.note(try Raw.query(.rowNote, state, Codec.encode(read), key: [key])) else { throw .undecodableOutput }
        return v
    }

    /// ejb.9, Lean `adoptProposal s r`: the record "Use the bar's current order" would save, or `nil` (no proposal: the shown verdict of `read` is not `differs`).
    /// The decision is Lean's: Swift only encodes the read and decodes the record.
    public static func adoptProposal(_ state: DecisionState, _ read: Read) throws(DecisionError) -> [Key]? {
        guard let v = Codec.adopt(try Raw.query(.adopt, state, Codec.encode(read))) else { throw .undecodableOutput }
        return v
    }

    /// `rowVerdict s.record (s.view r) k`
    public static func rowVerdict(_ state: DecisionState, _ read: Read, _ key: Key) throws(DecisionError) -> RowVerdict {
        guard let v = Codec.rowVerdict(try Raw.query(.rowVerdict, state, Codec.encode(read), key: [key])) else { throw .undecodableOutput }
        return v
    }
}

/// The word-level calls (internal; `@testable` tests feed them malformed words to check that the Lean side refuses them).
enum Raw {
    enum Query { case status, shownVerdict, rowLine, rowVerdict, rowNote, adopt }

    /// Returns the payload after the ok tag. Tag 1 (malformed) throws; anything else is undecodable.
    static func payload(_ r: inout sm_result) throws(DecisionError) -> [UInt32] {
        defer { sm_result_free(&r) }
        guard let w = r.words, r.n >= 1 else { throw .runtimeUnavailable }
        let all = Array(UnsafeBufferPointer(start: w, count: r.n))
        switch all[0] {
        case 0: return Array(all.dropFirst())
        case 1: if all.count == 1 { throw .malformedInput } else { throw .undecodableOutput }
        default: throw .undecodableOutput
        }
    }

    /// Test support: Lean's own reading (by name) of an event's words, from the real export.
    static func describeEvent(_ words: [UInt32]) throws(DecisionError) -> String {
        var r = sm_result(words: nil, n: 0)
        words.withUnsafeBufferPointer { sm_describe_event($0.baseAddress, $0.count, &r) }
        let bytes = try payload(&r)
        return String(decoding: bytes.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
    }

    static func step(_ state: DecisionState, _ words: [UInt32]) throws(DecisionError) -> (DecisionState, [UInt32]) {
        var r = sm_result(words: nil, n: 0)
        let h = words.withUnsafeBufferPointer { sm_step(state.handle, $0.baseAddress, $0.count, &r) }
        guard let h else { sm_result_free(&r); throw .runtimeUnavailable }
        let next = DecisionState(adopting: h)   // owns the new reference whatever the answer, so nothing leaks on a throw
        return (next, try payload(&r))
    }

    static func query(_ q: Query, _ state: DecisionState, _ read: [UInt32], key: [UInt32] = []) throws(DecisionError) -> [UInt32] {
        var r = sm_result(words: nil, n: 0)
        read.withUnsafeBufferPointer { rd in
            key.withUnsafeBufferPointer { k in
                switch q {
                case .status: sm_status(state.handle, rd.baseAddress, rd.count, &r)
                case .shownVerdict: sm_shown_verdict(state.handle, rd.baseAddress, rd.count, &r)
                case .rowLine: sm_row_line(state.handle, rd.baseAddress, rd.count, k.baseAddress, k.count, &r)
                case .adopt: sm_adopt(state.handle, rd.baseAddress, rd.count, &r)
                case .rowNote: sm_row_note(state.handle, rd.baseAddress, rd.count, k.baseAddress, k.count, &r)
                case .rowVerdict: sm_row_verdict(state.handle, rd.baseAddress, rd.count, k.baseAddress, k.count, &r)
                }
            }
        }
        return try payload(&r)
    }
}
