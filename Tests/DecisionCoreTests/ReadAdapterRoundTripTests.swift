import Testing
import Foundation
import SommelierCore
@testable import DecisionCore

/// sommelier-ejb.13: a Read produced by the real `ReadAdapter` survives the real boundary. Swift's encoder -> Lean's `describe_event` -> a name that
/// equals the hand-written Swift-side name of the event Swift meant (Names does not use Codec).
@Suite struct ReadAdapterRoundTripTests {
    private func k(_ n: Int) -> ItemKey { .status(ownerKey: "app.\(n)", autosaveName: "a\(n)") }
    private let chev = ItemKey.status(ownerKey: "chev", autosaveName: "c")

    @Test func anAdaptedReadIsNamedByLeanAsSwiftMeantIt() throws {
        var keys = CoreKeys()
        var cases: [(ObservedOrder, ReadContext)] = []
        var fresh = ObservedOrder(onBar: [k(1), k(2), k(3), chev, k(4)], parked: [k(8), k(9)], systemOverflow: [k(1), k(2)], overflowChevron: chev)
        fresh.chevronAnyKey = chev; fresh.chevronPresent = true
        fresh.foldedParked = [k(8)]; fresh.uncorroborated = [k(4)]
        cases.append((fresh, ReadContext(kind: .pass, unreadOwners: [UnreadOwner(pid: 1, bundleID: "app.3")], churnZone: [k(3), k(4)])))
        var stale = ObservedOrder(onBar: [k(1), k(2), chev, k(3)], parked: [], systemOverflow: [k(1)])
        stale.chevronAnyKey = chev; stale.chevronPresent = true
        cases.append((stale, ReadContext(kind: .poll, settled: false, level: .completeExceptSelfPositioning)))
        cases.append((ObservedOrder(onBar: [], parked: []), ReadContext(kind: .pass, level: .incomplete)))
        cases.append((ObservedOrder(onBar: [k(5), k(6)], parked: []), ReadContext(kind: .pass)))
        let record = [k(3), k(1), k(2), k(4), k(5)]
        var bad = 0
        for (o, c) in cases {
            let a = try ReadAdapter.adapt(o, context: c, record: record, keys: &keys)
            for e in [Event.read(a.read), .userEdit(record: a.record, moved: []), .userEdit(record: a.record, moved: Array(a.record.prefix(1)))] {
                let got = try Raw.describeEvent(Codec.encode(e))
                if got != Names.event(e) { bad += 1; print("mismatch: Swift meant", Names.event(e), "Lean read", got) }
            }
        }
        #expect(bad == 0)
        #expect(keys.id(for: chev) == nil)
    }

    @Test func anAdaptedReadAndRecordAreAcceptedByTheCore() throws {
        var keys = CoreKeys()
        var o = ObservedOrder(onBar: [k(1), k(2), k(3)], parked: [])
        o.uncorroborated = []
        let record = [k(2), k(1), k(3)]
        let a = try ReadAdapter.adapt(o, context: ReadContext(kind: .pass), record: record, keys: &keys)
        let s = try DecisionState(record: a.record)
        let (_, actions) = try DecisionCore.step(s, .read(a.read))
        #expect(actions.count <= 1)    // the core decodes the adapted read and answers (an order move or none), never a decode error
        let st = try DecisionCore.status(s, a.read)
        _ = st
    }
}
