import Testing
import Foundation
@testable import DecisionCore

private func sampleRead() -> Read {
    Read(kind: .pass, chevron: .fresh, level: .complete, settled: true, stripOpen: false, drawn: [1, 2], pile: [3], folded: [], trusted: [1, 2, 3], nearFold: [])
}

/// Malformed input returns an error, never a value (the Lean side refuses; Swift surfaces it).
@Suite struct MalformedInputTests {
    static let badEvents: [[UInt32]] = [
        [], [9], [2, 0], [3], [4, 1, 7, 0], [4, 1, 0, 2], [5, 5], [1, 5, 1, 2], [1, 0, 0, 7], [0], [0, 0, 0],
        [0, 2, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0],            // kind 2 is not a ReadKind
        [0, 0, 3, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0],            // chevron 3
        [0, 0, 0, 3, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0],            // level 3
        [0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0],            // settled = 2 is not a Bool
        [0, 0, 0, 0, 1, 0, 1, 0, 9, 1, 2, 0, 0, 0, 0, 0],      // list length 9 with 2 words left
        [0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 7],         // trailing word
        [4294967295],                                          // unknown tag
    ]

    @Test func stepRefusesMalformedEventsAndLeavesTheStateUnchanged() throws {
        let s0 = try DecisionState(record: [1, 2, 3])
        // advance to a non-trivial state so "unchanged" is observable
        let (s, _) = try DecisionCore.step(s0, .userEdit(record: [3, 1, 2], moved: [3]))
        let before = try DecisionCore.shownVerdict(s, sampleRead())
        for w in Self.badEvents {
            #expect(throws: DecisionError.malformedInput, "event words \(w)") { _ = try Raw.step(s, w) }
        }
        _ = try Raw.step(s, [5])        // a valid event still works afterwards
        #expect(try DecisionCore.shownVerdict(s, sampleRead()) == before)
        // and the returned state of a refused step is the same state: stepping it equals stepping the original
        let good = Event.read(sampleRead())
        let (n1, a1) = try DecisionCore.step(s, good)
        var refused: DecisionState?
        do { _ = try Raw.step(s, [9]) } catch { refused = s }
        let (n2, a2) = try DecisionCore.step(try #require(refused), good)
        #expect(a1 == a2)
        #expect(try DecisionCore.status(n1, sampleRead()) == DecisionCore.status(n2, sampleRead()))
    }

    @Test func queriesRefuseMalformedReadsAndKeys() throws {
        let s = try DecisionState(record: [1, 2, 3])
        let good = Codec.encode(sampleRead())
        for q in [Raw.Query.status, .shownVerdict] {
            for bad in [[], [0], [7, 0, 0, 1, 0, 1, 0], Array(good.dropLast()), good + [1]] as [[UInt32]] {
                #expect(throws: DecisionError.malformedInput) { _ = try Raw.query(q, s, bad) }
            }
            _ = try Raw.query(q, s, good)
        }
        for q in [Raw.Query.rowLine, .rowVerdict] {
            #expect(throws: DecisionError.malformedInput) { _ = try Raw.query(q, s, [], key: [1]) }
            #expect(throws: DecisionError.malformedInput) { _ = try Raw.query(q, s, good, key: []) }          // no key
            #expect(throws: DecisionError.malformedInput) { _ = try Raw.query(q, s, good, key: [1, 2]) }       // two words
            #expect(throws: DecisionError.malformedInput) { _ = try Raw.query(q, s, good + [9], key: [1]) }
            _ = try Raw.query(q, s, good, key: [1])
        }
    }

    @Test func errorIsDistinctFromEveryOkAnswer() throws {
        let s = try DecisionState(record: [1, 2])
        // the ok answer carries tag 0 and the error tag 1: a refused call can never decode as an empty action list
        let (_, ok) = try Raw.step(s, [5])
        #expect(ok.isEmpty)
        #expect(throws: DecisionError.malformedInput) { _ = try Raw.step(s, [6]) }
    }

    @Test func outputDecodersRefuseWordsTheLeanSideNeverProduces() {
        #expect(Codec.actions([1, 2, 3]) == nil)
        #expect(Codec.actions([1, 2, 3, 4, 5]) == nil)          // rel 2 is not before/after
        #expect(Codec.actions([1, 0, 3, 2, 0]) == nil)          // strip 2
        #expect(Codec.status([]) == nil); #expect(Codec.status([9]) == nil); #expect(Codec.status([3, 7]) == nil); #expect(Codec.status([3]) == nil)
        #expect(Codec.verdict([]) == nil); #expect(Codec.verdict([4]) == nil); #expect(Codec.verdict([2, 1]) == nil)
        #expect(Codec.row([7]) == nil); #expect(Codec.row([]) == nil); #expect(Codec.row([1, 1]) == nil)
        #expect(Codec.rowVerdict([6]) == nil); #expect(Codec.rowVerdict([]) == nil)
    }
}

/// The module is pure: no Foundation, clock, file, AX, CoreGraphics or logging in Sources/DecisionCore.
@Suite struct PurityTests {
    @Test func decisionCoreSourcesUseNoIOClockAXOrLogging() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/DecisionCore")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 3)
        let forbidden = ["import Foundation", "import AppKit", "import Cocoa", "import ApplicationServices", "import CoreGraphics", "import os", "import OSLog",
                         "import Dispatch", "Date(", "DispatchTime", "ProcessInfo", "FileManager", "FileHandle", "URL(", "UserDefaults", "NSLog", "Logger",
                         "print(", "debugPrint(", "AXUIElement", "CGEvent", "AXValue", "Thread.", "sleep(", "usleep(", "fopen", "fwrite", "getenv"]
        for f in files {
            let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            // ignore comment lines: they may mention these words
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for bad in forbidden { #expect(!code.contains(bad), "\(f) uses \(bad)") }
        }
    }
}
