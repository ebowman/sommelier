import Foundation
@testable import DecisionCore

/// The expected values computed by Lean (`lake exe fixture`, run by scripts/build-lean-core.sh into build/LeanCore/fixture.txt).
/// Format: see lean/Fixture.lean.
struct FixtureStep { var words: [UInt32]; var event: Event; var expected: String }
struct FixtureProbe { var read: Read; var status: String; var verdict: String; var rows: [(key: Key, row: String, rowVerdict: String, note: String)] }
enum FixtureItem { case step(FixtureStep), probe(FixtureProbe) }
struct FixtureCase { var name: String; var record: [Key]; var items: [FixtureItem] }

/// Swift decoder of input words (test-only; the app never decodes inputs). Mirrors Lean `decEvent`/`decRead`.
enum TestDecode {
    static func list(_ w: inout ArraySlice<UInt32>) -> [Key] {
        let n = Int(w.removeFirst()); let l = Array(w.prefix(n)); w = w.dropFirst(n); return l
    }
    static func read(_ words: [UInt32]) -> Read {
        var w = ArraySlice(words)
        let kind = ReadKind(rawValue: w.removeFirst())!, chevron = ChevronRead(rawValue: w.removeFirst())!, level = ReadLevel(rawValue: w.removeFirst())!
        let settled = w.removeFirst() == 1, stripOpen = w.removeFirst() == 1, observed = w.removeFirst() == 1, nfp = w.removeFirst() == 1
        let drawn = list(&w), pile = list(&w), folded = list(&w), trusted = list(&w), near = list(&w), unread = list(&w)
        precondition(w.isEmpty)
        return Read(kind: kind, chevron: chevron, level: level, settled: settled, stripOpen: stripOpen, drawn: drawn, pile: pile, folded: folded,
                    trusted: trusted, nearFold: near, observed: observed, unread: unread, notFullProven: nfp)
    }
    static func event(_ words: [UInt32]) -> Event {
        var w = ArraySlice(words)
        switch w.removeFirst() {
        case 0: return .read(read(Array(w)))
        case 1: let rec = list(&w); let mv = list(&w); return .userEdit(record: rec, moved: mv)
        case 2: return .userRetry
        case 3: return .retryKey(w.removeFirst())
        case 4: let k = w.removeFirst(); let o = Outcome(rawValue: w.removeFirst())!; return .moveResult(k, o, posted: w.removeFirst() == 1)
        case 5: return .passBoundary
        default: fatalError("bad event words \(words)")
        }
    }
}

enum Fixture {
    static var path: String {
        if let p = ProcessInfo.processInfo.environment["DECISIONCORE_FIXTURE"] { return p }
        // Tests/DecisionCoreTests/FixtureLoader.swift -> repo root
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("build/LeanCore/fixture.txt").path
    }

    static func words(_ s: Substring) -> [UInt32] { s.split(separator: " ").map { UInt32($0)! } }

    static let all: [FixtureCase] = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("no fixture at \(path): run scripts/build-lean-core.sh")
        }
        var cases: [FixtureCase] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("G") { continue }   // gesture cases (ejb.32) are read by `GestureFixture.all`
            if line.hasPrefix("CASE ") { cases.append(FixtureCase(name: String(line.dropFirst(5)), record: [], items: [])); continue }
            if line.hasPrefix("INIT") { cases[cases.count - 1].record = words(line.dropFirst(4)); continue }
            let g = line.components(separatedBy: ";")
            if line.hasPrefix("EV ") {
                let w = words(Substring(g[0].dropFirst(3)))
                cases[cases.count - 1].items.append(.step(FixtureStep(words: w, event: TestDecode.event(w), expected: g[1].trimmingCharacters(in: .whitespaces))))
            } else if line.hasPrefix("PROBE ") {
                let rows: [(key: Key, row: String, rowVerdict: String, note: String)] = g.dropFirst(4).map { t in
                    let x = t.split(separator: " "); return (UInt32(x[0])!, String(x[1]), String(x[2]), String(x[3]))
                }
                cases[cases.count - 1].items.append(.probe(FixtureProbe(
                    read: TestDecode.read(words(Substring(g[0].dropFirst(6)))), status: g[1].trimmingCharacters(in: .whitespaces),
                    verdict: g[2].trimmingCharacters(in: .whitespaces), rows: rows)))
            } else { fatalError("unparsable fixture line: \(line.prefix(80))") }
        }
        return cases
    }()

    /// Replays one case through the linked proved code. Returns the number of mismatches (0 = agrees with Lean everywhere).
    static func mismatches(_ c: FixtureCase) throws -> Int {
        var bad = 0
        var s = try DecisionState(record: c.record)
        for item in c.items {
            switch item {
            case .step(let st):
                if Codec.encode(st.event) != st.words { bad += 1 }          // the Swift encoder emits exactly Lean's words
                let (n, a) = try DecisionCore.step(s, st.event)
                if Names.actions(a) != st.expected { bad += 1 }
                s = n
            case .probe(let p):
                if Names.status(try DecisionCore.status(s, p.read)) != p.status { bad += 1 }
                if Names.verdict(try DecisionCore.shownVerdict(s, p.read)) != p.verdict { bad += 1 }
                for r in p.rows {
                    if Names.row(try DecisionCore.row(s, p.read, r.key)) != r.row { bad += 1 }
                    if Names.rowVerdict(try DecisionCore.rowVerdict(s, p.read, r.key)) != r.rowVerdict { bad += 1 }
                    if Names.note(try DecisionCore.rowNote(s, p.read, r.key)) != r.note { bad += 1 }
                }
            }
        }
        return bad
    }
}

/// ejb.32: the gesture cases Lean printed (`lake exe fixture`): every field is text by NAME, parsed here with plain string code, never with the codec under test.
struct GestureFixture {
    var name: String
    var layout: Layout3
    var units: [Key: UInt32]
    var sys: Set<Key>
    var gesture: LayoutGesture
    var expected: String

    static func keys(_ s: Substring) -> [Key] {
        let inner = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inner.isEmpty ? [] : inner.split(separator: ",").map { Key($0)! }
    }
    /// `visible=[..] hidden=[..] alwaysHidden=[..]`
    static func layout(_ s: String) -> Layout3 {
        let parts = s.split(separator: " ")
        return Layout3(visible: keys(parts[0].dropFirst("visible=".count)), hidden: keys(parts[1].dropFirst("hidden=".count)),
                       alwaysHidden: keys(parts[2].dropFirst("alwaysHidden=".count)))
    }
    static func section(_ s: Substring) -> LayoutSection3 {
        switch s { case "visible": return .visible; case "hidden": return .hidden; case "alwaysHidden": return .alwaysHidden; default: fatalError("section \(s)") }
    }

    static let all: [GestureFixture] = {
        guard let text = try? String(contentsOfFile: Fixture.path, encoding: .utf8) else { fatalError("no fixture at \(Fixture.path)") }
        var out: [GestureFixture] = []
        var name = "", lay = Layout3(visible: [], hidden: [], alwaysHidden: []), units: [Key: UInt32] = [:], sys = Set<Key>(), g: LayoutGesture?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if !line.hasPrefix("G") { continue }   // the step/probe lines are read by `Fixture.all`
            if line.hasPrefix("GCASE ") { name = String(line.dropFirst(6)) }
            else if line.hasPrefix("GLAYOUT ") { lay = layout(String(line.dropFirst(8))) }
            else if line.hasPrefix("GUNITS") {
                units = [:]
                for p in line.dropFirst(6).split(separator: " ") { let x = p.split(separator: ":"); units[Key(x[0])!] = UInt32(x[1])! }
            } else if line.hasPrefix("GSYS") { sys = Set(line.dropFirst(4).split(separator: " ").map { Key($0)! }) }
            else if line.hasPrefix("GGESTURE ") {
                let x = line.dropFirst(9).split(separator: " ", maxSplits: 3)
                if x[0] == "hide" { g = .hideNotFitting(keys(x[1])) }
                else { g = .drop(Key(x[1])!, section(x[2]), index: x[3] == "none" ? nil : UInt32(x[3])!) }
            } else if line.hasPrefix("GEXPECT ") {
                out.append(GestureFixture(name: name, layout: lay, units: units, sys: sys, gesture: g!, expected: String(line.dropFirst(8))))
            } else { fatalError("unparsable fixture line: \(line.prefix(80))") }
        }
        return out
    }()
}
