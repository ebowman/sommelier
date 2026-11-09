import Testing
import Foundation
@testable import DecisionCore

/// Timing of the exported (fast, proved-equal) decision core on a 36-key record and a 25-key read (ejb.12).
/// Skipped unless SOMMELIER_PERF is set in the environment:  SOMMELIER_PERF=1 swift test --filter PerfTests
/// Worst case = the user dropped keys and the anchor rule gives no move, so every row/step reaches the fallback drag (the specification took
/// ~22 ms per call there).  Typical = the bar already matches the record.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_PERF"] != nil))
struct PerfTests {
    static let record: [Key] = Array(0..<36)
    static let drawnWorst: [Key] = (3..<28).reversed()                 // 25 keys, reversed: every owed key is misplaced, no anchor gap
    static let drawnTypical: [Key] = Array(3..<28)                     // 25 keys, in record order
    static func read(_ drawn: [Key]) -> Read {
        let pile = record.filter { !drawn.contains($0) }
        return Read(kind: .pass, chevron: .fresh, level: .complete, settled: true, stripOpen: false,
                    drawn: drawn, pile: pile, folded: [], trusted: drawn, nearFold: [])
    }
    static func state(owed: [Key]) throws -> DecisionState {
        let s0 = try DecisionState(record: record)
        if owed.isEmpty { return s0 }
        return try DecisionCore.step(s0, .userEdit(record: record, moved: owed)).0
    }

    /// microseconds per call, best of 3 rounds of `n`
    static func micros(_ n: Int, _ body: () throws -> Void) rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = ContinuousClock.now
            for _ in 0..<n { try body() }
            let d = ContinuousClock.now - t0
            let us = Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
            best = min(best, us / Double(n))
        }
        return best
    }

    @Test func timings() throws {
        var lines: [String] = []
        func report(_ name: String, _ us: Double) { lines.append(String(format: "%-46@ %10.1f us", name as NSString, us)) }
        let worst = Self.read(Self.drawnWorst), typical = Self.read(Self.drawnTypical)
        let owed1 = try Self.state(owed: [14])
        let owed2 = try Self.state(owed: [14, 15])
        let owed10 = try Self.state(owed: [10, 12, 14, 16, 18, 20, 22, 24, 26, 27])
        let none = try Self.state(owed: [])

        let stepWorst1 = try Self.micros(200) { _ = try DecisionCore.step(owed1, .read(worst)) }
        let stepWorst2 = try Self.micros(200) { _ = try DecisionCore.step(owed2, .read(worst)) }
        let stepWorst10 = try Self.micros(200) { _ = try DecisionCore.step(owed10, .read(worst)) }
        let stepTypical = try Self.micros(200) { _ = try DecisionCore.step(none, .read(typical)) }
        let stepTypicalOwed = try Self.micros(200) { _ = try DecisionCore.step(owed1, .read(typical)) }
        report("step, worst case (1 owed key)", stepWorst1)
        report("step, worst case (2 owed keys)", stepWorst2)
        report("step, worst case (10 owed keys)", stepWorst10)
        report("step, typical (nothing owed, bar in order)", stepTypical)
        report("step, typical (1 owed key, bar in order)", stepTypicalOwed)

        func rows(_ s: DecisionState, _ r: Read) throws { for k in Self.record { _ = try DecisionCore.row(s, r, k) } }
        let rows1 = try Self.micros(20) { try rows(owed1, worst) }
        let rows2 = try Self.micros(20) { try rows(owed2, worst) }
        let rows10 = try Self.micros(20) { try rows(owed10, worst) }
        let rowsTypical = try Self.micros(20) { try rows(none, typical) }
        report("rowLine x 36 rows, worst case (1 owed key)", rows1)
        report("rowLine x 36 rows, worst case (2 owed keys)", rows2)
        report("rowLine x 36 rows, worst case (10 owed keys)", rows10)
        report("rowLine x 36 rows, typical", rowsTypical)

        report("shownVerdict, worst case", try Self.micros(500) { _ = try DecisionCore.shownVerdict(owed1, worst) })
        report("shownVerdict, typical", try Self.micros(500) { _ = try DecisionCore.shownVerdict(none, typical) })
        report("status, worst case", try Self.micros(200) { _ = try DecisionCore.status(owed1, worst) })
        report("rowVerdict x 36 rows", try Self.micros(50) { for k in Self.record { _ = try DecisionCore.rowVerdict(owed1, worst, k) } })
        print("\n=== DecisionCore timings (36-key record, 25-key read) ===\n" + lines.joined(separator: "\n"))

        // the targets of ejb.12
        #expect(stepWorst1 < 2000)
        #expect(stepWorst2 < 2000)
        #expect(rows1 < 5000)
        #expect(rows2 < 5000)
    }
}
