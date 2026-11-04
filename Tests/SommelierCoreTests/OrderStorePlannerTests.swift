import Testing
@testable import SommelierCore

/// gdu.25: fallback order-store values must stay unique around the subject (never "duplicate position values").
@Suite struct OrderStorePlannerTests {
    // Larger value = further left.
    @Test func midpointBetweenNeighbours() {
        let p = OrderStorePlanner.plan(order: ["A", "S", "B"], subject: "S", values: ["A": 500, "B": 300, "S": 100])
        #expect(p == .init(updates: ["S": 400], rebased: false))
    }

    @Test func duplicatesElsewhereDoNotMatterAndOnlySubjectIsWritten() {
        // B and C tie (they were already ambiguous), the subject slots between A and B.
        let p = OrderStorePlanner.plan(order: ["A", "S", "B", "C", "D"], subject: "S",
                                       values: ["A": 1000, "B": 900, "C": 900, "D": 700, "S": 100])
        #expect(p == .init(updates: ["S": 950], rebased: false))
    }

    @Test func equalNeighbourValuesForceARebaseOfTheRunOnly() {
        // The subject must sit between A and B, which both carry 1000: no integer fits, so the run grows to include A.
        let p = OrderStorePlanner.plan(order: ["A", "S", "B", "C"], subject: "S",
                                       values: ["A": 1000, "B": 1000, "C": 500, "S": 100])!
        #expect(p.rebased)
        #expect(Set(p.updates.keys) == ["A", "S"])             // B and C are never touched
        let new = ["A": p.updates["A"] ?? 1000, "S": p.updates["S"]!, "B": 1000, "C": 500]
        #expect(new["A"]! > new["S"]! && new["S"]! > new["B"]! && new["B"]! > new["C"]!)
    }

    @Test func adjacentIntegersRebaseKeepingOrderAndSpacing() {
        // Between 301 and 300 no integer fits; the anchors above (A=1000) and below (C=100) leave plenty of room.
        let order = ["T", "A", "S", "B", "C"]
        let values: [String: Double] = ["T": 5000, "A": 301, "B": 300, "C": 100, "S": 50]
        let p = OrderStorePlanner.plan(order: order, subject: "S", values: values)!
        #expect(p.rebased)
        var merged = values
        for (k, v) in p.updates { merged[k] = v }
        let seq = order.map { merged[$0]! }
        #expect(zip(seq, seq.dropFirst()).allSatisfy { $0 - $1 >= 2 || $0 == 5000 })   // strictly ordered, spaced
        #expect(seq == seq.sorted(by: >))
        #expect(p.updates["T"] == nil && p.updates["C"] == nil)                       // outside the run: untouched
    }

    @Test func rightmostSlotUsesLeftNeighbourMinusTwoOrRebases() {
        #expect(OrderStorePlanner.plan(order: ["A", "S"], subject: "S", values: ["A": 400, "S": 900])
                == .init(updates: ["S": 398], rebased: false))
        let p = OrderStorePlanner.plan(order: ["A", "S"], subject: "S", values: ["A": 1, "S": 900])!
        #expect(p.rebased)
        let a = p.updates["A"] ?? 1, s = p.updates["S"] ?? 900
        #expect(a > s)
    }

    @Test func leftmostSlotUsesRightNeighbourPlusTwo() {
        #expect(OrderStorePlanner.plan(order: ["S", "B", "C"], subject: "S", values: ["B": 400, "C": 300, "S": 10])
                == .init(updates: ["S": 402], rebased: false))
    }

    @Test func missingSubjectOrValueIsNil() {
        #expect(OrderStorePlanner.plan(order: ["A", "B"], subject: "S", values: ["A": 1, "B": 2]) == nil)
        #expect(OrderStorePlanner.plan(order: ["A", "S"], subject: "S", values: [:]) == nil)
    }

    @Test func invertedNeighboursRebase() {
        // The store disagrees with the desired order (A < B): the run is re-based so A > S > B holds.
        let p = OrderStorePlanner.plan(order: ["A", "S", "B"], subject: "S", values: ["A": 100, "B": 200, "S": 150])!
        #expect(p.rebased)
        var m: [String: Double] = ["A": 100, "B": 200, "S": 150]
        for (k, v) in p.updates { m[k] = v }
        #expect(m["A"]! > m["S"]! && m["S"]! > m["B"]!)
    }
}
