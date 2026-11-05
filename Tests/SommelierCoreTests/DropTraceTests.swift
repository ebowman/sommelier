import Foundation
import Testing
@testable import SommelierCore

@Suite struct DropTraceTests {
    private func key(_ n: String) -> ItemKey { .status(ownerKey: n, autosaveName: "a") }
    private func row(_ k: ItemKey, ghost: Bool = false, boundary: Bool = false) -> ArrangeRow {
        ArrangeRow(key: k, title: "\(k)", ownerName: "o", ownerBundleID: nil, ownerPID: nil, badge: .none, draggable: true, canHide: true,
                   isAnchor: false, isGhost: ghost, isBoundary: boundary, notFitting: false, notRunning: false, unit: HideUnitRule.ownerKeys.unit(of: k), unitMates: [], capabilityNote: nil)
    }
    private let name: (ItemKey) -> String = { k in
        if case .status(let o, _) = k { return o.uppercased() }
        return "\(k)"
    }
    private func observed(_ n: Int, stale: Set<ItemKey> = []) -> ObservedOrder {
        ObservedOrder(onBar: (0..<n).map { key("k\($0)") }, parked: [], staleOnBar: stale)
    }

    @Test func intentWithBothNeighbours() {
        let a = key("a"), b = key("b"), m = key("m")
        let line = DropTrace.intentLine(id: 7, key: m, section: .visible, slot: 1, rows: [row(a), row(m), row(b)],
                                        observed: observed(24, stale: [a, b]), settled: true, displayName: name)
        #expect(line == "drop#7 intent: M(\(m)) -> visible slot 1; between A(\(a)) and B(\(b)); observed: onBar=24 stale=2 settled=true")
    }

    @Test func intentAtStartAndEnd() {
        let a = key("a"), m = key("m")
        let start = DropTrace.intentLine(id: 1, key: m, section: .hidden, slot: 0, rows: [row(a)], observed: observed(3), settled: false, displayName: name)
        #expect(start.contains("between start and A(\(a))"))
        #expect(start.hasSuffix("onBar=3 stale=0 settled=false"))
        let end = DropTrace.intentLine(id: 2, key: m, section: .hidden, slot: 5, rows: [row(a)], observed: observed(3), settled: true, displayName: name)
        #expect(end.contains("between A(\(a)) and end"))
        let alone = DropTrace.intentLine(id: 3, key: m, section: .visible, slot: 0, rows: [], observed: observed(0), settled: true, displayName: name)
        #expect(alone.contains("between start and end"))
    }

    @Test func intentSkipsGhostsBoundaryAndSelf() {
        let a = key("a"), b = key("b"), m = key("m"), g = key("g"), c = key("c")
        let line = DropTrace.intentLine(id: 4, key: m, section: .visible, slot: 3, rows: [row(a), row(g, ghost: true), row(m), row(c, boundary: true), row(b)],
                                        observed: observed(1), settled: true, displayName: name)
        #expect(line.contains("between A(\(a)) and B(\(b))"))
    }

    @Test func layoutLineAfterBeforePlaced() {
        let a = key("a"), b = key("b"), m = key("m")
        let l = Layout(visible: [a, m, b], placed: [m])
        #expect(DropTrace.layoutLine(id: 7, key: m, layout: l) == "drop#7 layout: visible after \(a) before \(b); placed=yes")
        let l2 = Layout(visible: [b], hidden: [m, a])
        #expect(DropTrace.layoutLine(id: 8, key: m, layout: l2) == "drop#8 layout: hidden after start before \(a); placed=no")
        #expect(DropTrace.layoutLine(id: 9, key: a, layout: l2).contains("hidden after \(m) before end"))
        #expect(DropTrace.layoutLine(id: 10, key: key("zz"), layout: l2).contains("no section"))
    }

    @Test func aroundAndBetween() {
        let ks = (0..<6).map { key("k\($0)") }
        #expect(DropTrace.around(ks[3], in: ks) == "\(ks[1]) \(ks[2]) [\(ks[3])] \(ks[4]) \(ks[5])")
        #expect(DropTrace.around(ks[0], in: ks) == "[\(ks[0])] \(ks[1]) \(ks[2])")
        #expect(DropTrace.around(key("x"), in: ks).contains("not on the bar"))
        #expect(DropTrace.between(ks[0], in: ks) == "between start and \(ks[1])")
        #expect(DropTrace.between(ks[5], in: ks) == "between \(ks[4]) and end")
    }

    @Test func longBarListsAreTruncated() {
        let xs = (0..<30).map(String.init)
        let t = DropTrace.truncated(xs)
        #expect(t == (0..<12).map(String.init).joined(separator: ",") + "…")
        #expect(DropTrace.truncated(["1", "2"]) == "1,2")
        #expect(DropTrace.truncated((0..<12).map(String.init)).hasSuffix("11"))
    }

    @Test func trackerCarriesDropIDThroughRecordStampRetryAndDoneLine() {
        let a = key("a"), m = key("m"), b = key("b")
        var t = ArrangeTracker()
        let now = Date()
        let ticket = t.record([m], passesStarted: 3, now: now, awaitingStamp: true, dropID: 7)
        #expect(t.entries[m]?.dropID == 7)
        t.stamp(ticket: ticket, passesStartedAtRevision: 3)
        #expect(t.entries[m]?.dropID == 7)
        t.retry(passesStarted: 3, now: now)
        #expect(t.entries[m]?.dropID == 7)
        let layout = Layout(visible: [a, m, b], placed: [m])
        let lines = t.update(observed: ObservedOrder(onBar: [a, m, b], parked: []), layout: layout, perItem: [m: .inPlace], passSequence: 4,
                             showHiddenSection: false, now: now.addingTimeInterval(2))
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("drop#7 done: "))
        #expect(lines[0].contains("verified in place"))
        #expect(lines[0].hasSuffix("final: between \(a) and \(b)"))
    }

    @Test func failedDoneLineAndNoDropIDKeepsPlainText() {
        let a = key("a"), m = key("m")
        var t = ArrangeTracker()
        let now = Date()
        t.record([m], passesStarted: 0, now: now, dropID: 2)
        let layout = Layout(visible: [a, m], placed: [m])
        let failed = t.update(observed: ObservedOrder(onBar: [m, a], parked: []), layout: layout,
                              perItem: [m: .failed(.timeout)], passSequence: 1, showHiddenSection: false, now: now.addingTimeInterval(1))
        #expect(failed.first?.hasPrefix("drop#2 done: ") == true)
        #expect(failed.first?.contains("FAILED") == true)
        #expect(failed.first?.hasSuffix("final: between start and \(a)") == true)

        var t2 = ArrangeTracker()
        t2.record([m], passesStarted: 0, now: now)
        let plain = t2.update(observed: ObservedOrder(onBar: [a, m], parked: []), layout: layout, perItem: [m: .inPlace], passSequence: 1,
                              showHiddenSection: false, now: now.addingTimeInterval(1))
        #expect(plain.first?.hasPrefix("\(m) verified in place") == true)
        #expect(!(plain.first ?? "").contains("final:"))
    }

    @Test func rejectedAndDoneLines() {
        #expect(DropTrace.rejectedLine(id: 5, why: "nope") == "drop#5 rejected: nope")
        #expect(DropTrace.doneLine(id: 5, outcome: "noop") == "drop#5 done: noop")
    }
}
