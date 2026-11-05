import Testing
import Foundation
@testable import SommelierCore

@Suite struct OrderModeTests {
    static let a = ItemKey(storeKey: "status:com.example::A")!
    static let b = ItemKey(storeKey: "status:com.other::B")!
    static let c = ItemKey(storeKey: "status:com.third::C")!
    static let legacy = #"{"schemaVersion":1,"visible":["status:com.example::A","status:com.other::B"],"hidden":["status:com.third::C"],"newItemPolicy":"visibleAtEnd","placed":["status:com.other::B"]}"#

    @Test func emptyAndDefaultAreMacOSOwns() {
        #expect(Layout.empty.orderMode == .macOSOwns)
        #expect(Layout().orderMode == .macOSOwns)
        #expect(!Layout().enforcesOrder)
        #expect(Layout(orderMode: .placedOnly).enforcesOrder)
    }

    @Test func legacyJSONMigratesToMacOSOwnsKeepingPlaced() throws {
        let l = try JSONDecoder().decode(Layout.self, from: Data(Self.legacy.utf8))
        #expect(l.orderMode == .macOSOwns)
        #expect(l.placed == [Self.b])
        let d = try Layout.decode(Data(Self.legacy.utf8)).layout
        #expect(d.orderMode == .macOSOwns)
        #expect(d.placed == [Self.b])
        #expect(d.visible == [Self.a, Self.b])
    }

    @Test(arguments: OrderMode.allCases) func roundTrip(_ m: OrderMode) throws {
        let l = Layout(visible: [Self.a, Self.b], hidden: [Self.c], placed: [Self.a], orderMode: m)
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == l)
        #expect(try Layout.decode(data).layout.orderMode == m)
    }

    @Test(arguments: OrderMode.allCases) func encodeAlwaysWritesTheKey(_ m: OrderMode) throws {
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Layout(orderMode: m))) as? [String: Any]
        #expect(obj?["orderMode"] as? String == m.rawValue)
    }

    @Test func unknownValueIsADecodingError() {
        let json = Data(#"{"visible":[],"orderMode":"bogus"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Layout.self, from: json) }
        #expect(throws: DecodingError.self) { try Layout.decode(json) }
    }

    @Test func withOrderModeChangesOnlyTheMode() {
        let l = Layout(visible: [Self.a, Self.b], hidden: [Self.c], placed: [Self.b])
        let p = l.withOrderMode(.placedOnly)
        #expect(p.orderMode == .placedOnly)
        #expect(p.withOrderMode(.macOSOwns) == l)
        #expect(p.placed == l.placed && p.visible == l.visible && p.isValid)
    }

    @Test func helpersKeepTheMode() {
        var l = Layout(visible: [Self.a, Self.b], hidden: [Self.c], orderMode: .placedOnly)
        l.markPlaced([Self.a])
        #expect(l.orderMode == .placedOnly)
        l.move(Self.b, to: .hidden)
        #expect(l.orderMode == .placedOnly)
        #expect(l.pruningPlaced().orderMode == .placedOnly)
        l.append(Self.b, to: .visible)
        l.reorder(Self.b, in: .visible, toIndex: 0)
        l.remove(Self.c)
        #expect(l.orderMode == .placedOnly)
        #expect(l.validated().orderMode == .placedOnly)
        #expect(l.normalizedHideUnits().layout.orderMode == .placedOnly)
        #expect(l.section(of: Self.a) == .visible && l.keys(in: .visible).contains(Self.a))
    }
}
