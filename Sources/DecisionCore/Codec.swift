// The token codec: mirrors lean/Sommelier/Ffi.lean (encode for inputs, decode for outputs). The Lean round-trip theorems
// (`decEvent_enc`, `decActions_enc`, ...) prove the Lean half; DecisionCoreTests check this half against the Lean fixtures.

enum Codec {
    static func b(_ x: Bool) -> UInt32 { x ? 1 : 0 }
    static func list(_ l: [Key], into w: inout [UInt32]) { w.append(UInt32(l.count)); w.append(contentsOf: l) }

    static func encode(_ r: Read) -> [UInt32] {
        var w: [UInt32] = [r.kind.rawValue, r.chevron.rawValue, r.level.rawValue, b(r.settled), b(r.stripOpen), b(r.observed), b(r.notFullProven)]
        list(r.drawn, into: &w); list(r.pile, into: &w); list(r.folded, into: &w)
        list(r.trusted, into: &w); list(r.nearFold, into: &w); list(r.unread, into: &w)
        return w
    }

    static func encode(_ e: Event) -> [UInt32] {
        switch e {
        case .read(let r): return [0] + encode(r)
        case .userEdit(let rec, let mv):
            var w: [UInt32] = [1]; list(rec, into: &w); list(mv, into: &w); return w
        case .userRetry: return [2]
        case .retryKey(let k): return [3, k]
        case .moveResult(let k, let o, let p): return [4, k, o.rawValue, b(p)]
        case .passBoundary: return [5]
        }
    }

    // MARK: outputs (each takes the payload after the ok tag; nil = not an encoding the Lean side produces)

    static func bool(_ w: UInt32) -> Bool? { w == 0 ? false : (w == 1 ? true : nil) }

    static func actions(_ w: [UInt32]) -> [Action]? {
        guard w.count % 5 == 0 else { return nil }
        var out: [Action] = []
        var i = 0
        while i < w.count {
            guard let strip = bool(w[i + 3]), let user = bool(w[i + 4]) else { return nil }
            let rel: Rel
            switch w[i + 1] { case 0: rel = .before(w[i + 2]); case 1: rel = .after(w[i + 2]); default: return nil }
            out.append(Action(subject: w[i], rel: rel, strip: strip, user: user))
            i += 5
        }
        return out
    }

    static func why(_ w: UInt32) -> Why? {
        switch w { case 0: return .stopped; case 1: return .barFull; case 2: return .plain; default: return nil }
    }

    static func status(_ w: [UInt32]) -> Status? {
        guard let h = w.first else { return nil }
        switch (h, w.count) {
        case (0, 1): return .moving
        case (1, 1): return .matches
        case (2, _): return .matchesExcept(Array(w.dropFirst()))
        case (3, 2): return why(w[1]).map(Status.differs)
        case (4, 1): return .checking
        default: return nil
        }
    }

    static func verdict(_ w: [UInt32]) -> Verdict? {
        guard let h = w.first else { return nil }
        switch (h, w.count) {
        case (0, 1): return .matches
        case (1, _): return .matchesExcept(Array(w.dropFirst()))
        case (2, 1): return .differs
        case (3, 1): return .cannotTell
        default: return nil
        }
    }

    static func row(_ w: [UInt32]) -> Row? {
        guard w.count == 1 else { return nil }
        switch w[0] {
        case 0: return .moving; case 1: return .waiting; case 2: return .tick; case 3: return .behind
        case 4: return .notWherePut; case 5: return .notOnBar; case 6: return .cannotTell
        default: return nil
        }
    }

    static func rowVerdict(_ w: [UInt32]) -> RowVerdict? {
        guard w.count == 1 else { return nil }
        switch w[0] {
        case 0: return .inOrder; case 1: return .behindChevron; case 2: return .behindOutOfTurn
        case 3: return .notOnBar; case 4: return .outOfPlace; case 5: return .cannotTell
        default: return nil
        }
    }
}
