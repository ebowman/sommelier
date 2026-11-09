import Testing
import Foundation
@testable import DecisionCore

/// The linked C must agree with the Lean functions run by Lean itself (fixture: lean/Fixture.lean). With the round-trip theorems this is the
/// toolchain-drift guard: a different Lean, leanc or shim that changes any answer fails here.
@Suite(.serialized) struct DifferentialTests {
    static let named = Fixture.all.filter { !$0.name.hasPrefix("fuzz") }
    static let fuzz = Fixture.all.filter { $0.name.hasPrefix("fuzz") }

    @Test func namedExampleTracesAgreeWithLean() throws {
        #expect(Self.named.count >= 20)
        var total = 0
        for c in Self.named {
            let bad = try Fixture.mismatches(c)
            #expect(bad == 0, "case \(c.name): \(bad) mismatches")
            total += c.items.count
        }
        print("named cases:", Self.named.count, "items:", total)
        let names = Set(Self.named.map(\.name))
        for required in ["W", "W2", "drop-b-mutual", "drop-c-nogap", "stale-chevron-pile-memory", "incomplete-read", "poll-read"] {
            #expect(names.contains(required), "missing \(required)")
        }
    }

    @Test func fuzzTracesAgreeWithLean() throws {
        #expect(Self.fuzz.count == 2000)
        var bad = 0, steps = 0, probes = 0, nonEmpty = 0
        var kinds = Set<String>()
        for c in Self.fuzz {
            bad += try Fixture.mismatches(c)
            for i in c.items {
                switch i {
                case .step(let s): steps += 1; if !s.expected.isEmpty { nonEmpty += 1 }
                case .probe(let p): probes += 1; kinds.insert(p.status)
                }
            }
        }
        print("fuzz traces:", Self.fuzz.count, "events:", steps, "with actions:", nonEmpty, "probes:", probes, "distinct statuses:", kinds.count)
        #expect(bad == 0)
        #expect(nonEmpty > 1000)      // the traces really ask for drags
        #expect(kinds.count >= 4)     // and the probes see different statuses
    }

    /// The INPUT direction, through the real export: Lean decodes the words Swift's encoder produced and names the event it got; the name must equal
    /// the Swift-side name of the event Swift meant. Covers every Event/Read case (enumerated below) and every event of every fixture trace.
    @Test func leanReadsEveryInputTheWaySwiftMeantIt() throws {
        var events: [Event] = [.userRetry, .passBoundary, .retryKey(0), .retryKey(7), .userEdit(record: [], moved: []), .userEdit(record: [3, 1, 2], moved: [3, 1])]
        for o in Outcome.allCases { for p in [false, true] { events.append(.moveResult(4, o, posted: p)) } }
        for kind in ReadKind.allCases { for ch in ChevronRead.allCases { for lv in ReadLevel.allCases {
            for (i, b) in [false, true].enumerated() {
                events.append(.read(Read(kind: kind, chevron: ch, level: lv, settled: b, stripOpen: !b, drawn: [1, 2], pile: [3], folded: [4, 5, 6], trusted: [7],
                                         nearFold: [8, 9], observed: !b, unread: [10, 11, 12, 13], notFullProven: i == 1)))
                events.append(.read(Read(kind: kind, chevron: ch, level: lv, settled: !b, stripOpen: b, drawn: [], pile: [], folded: [], trusted: [], nearFold: [],
                                         observed: b, unread: [], notFullProven: i == 0)))
            } } } }
        for c in Self.named + Self.fuzz.prefix(200) { for case .step(let st) in c.items { events.append(st.event) } }
        var bad = 0
        for e in events {
            let got = try Raw.describeEvent(Codec.encode(e))
            if got != Names.event(e) { bad += 1; if bad < 4 { print("input mismatch: Swift meant", Names.event(e), "Lean read", got) } }
        }
        #expect(bad == 0)
        #expect(events.count > 100)
    }

    /// Negative control: the same check, fed a deliberately wrong expectation, must report it.
    @Test func negativeControlDetectsADifference() throws {
        var c = try #require(Self.fuzz.first { c in c.items.contains { if case .step(let s) = $0 { return !s.expected.isEmpty } else { return false } } })
        #expect(try Fixture.mismatches(c) == 0)
        for (i, item) in c.items.enumerated() {
            if case .step(var s) = item, !s.expected.isEmpty { s.expected = "99 " + s.expected; c.items[i] = .step(s); break }
        }
        #expect(try Fixture.mismatches(c) == 1)
        var d = try #require(Self.fuzz.first { c in c.items.contains { if case .probe = $0 { return true } else { return false } } })
        for (i, item) in d.items.enumerated() {
            if case .probe(var p) = item { p.status = (p.status == "checking" ? "moving" : "checking"); d.items[i] = .probe(p); break }
        }
        #expect(try Fixture.mismatches(d) >= 1)
    }

    /// Timing, for the report (not a pass/fail threshold): per-call cost of step and the queries on fixture inputs.
    @Test func timing() throws {
        var stepNs: [UInt64] = []; var statusNs: [UInt64] = []; var rowNs: [UInt64] = []; var verdictNs: [UInt64] = []
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        for c in Self.fuzz.prefix(300) {
            var s = try DecisionState(record: c.record)
            for item in c.items {
                switch item {
                case .step(let st): let t = now(); let (n, _) = try DecisionCore.step(s, st.event); stepNs.append(now() - t); s = n
                case .probe(let p):
                    var t = now(); _ = try DecisionCore.status(s, p.read); statusNs.append(now() - t)
                    t = now(); _ = try DecisionCore.shownVerdict(s, p.read); verdictNs.append(now() - t)
                    t = now(); _ = try DecisionCore.row(s, p.read, p.rows[0].key); rowNs.append(now() - t)
                }
            }
        }
        func rep(_ n: String, _ a: [UInt64]) {
            let sorted = a.sorted(); print("timing \(n): n=\(a.count) median \(sorted[a.count / 2] / 1000) us, p99 \(sorted[a.count * 99 / 100] / 1000) us, max \(sorted.last! / 1000) us")
        }
        rep("step", stepNs); rep("status", statusNs); rep("shownVerdict", verdictNs); rep("row", rowNs)
    }
}
