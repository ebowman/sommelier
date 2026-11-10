import Testing
import Foundation
@testable import DecisionCore

/// ejb.32: gestures through the linked proved code (Lean `applyGesture`).
@Suite(.serialized) struct GestureTests {
    /// Every case Lean printed (named examples + seeded random layouts with nine-key units, system blocks, absent keys, out-of-range indices) is replayed through
    /// the linked C and must give exactly the answer Lean computed itself. Expected values are compared BY NAME (Swift renders its own result).
    @Test func gesturesAgreeWithLean() throws {
        let all = GestureFixture.all
        #expect(all.count >= 1500)
        var bad = 0, hides = 0, drops = 0
        for c in all {
            let r = try DecisionCore.applyGesture(layout: c.layout, units: c.units, immovable: c.sys, gesture: c.gesture)
            if Names.gestureResult(r) != c.expected { bad += 1; if bad < 4 { print("MISMATCH \(c.name): got \(Names.gestureResult(r)) expected \(c.expected)") } }
            if case .hideNotFitting = c.gesture { hides += 1 } else { drops += 1 }
        }
        print("gesture cases:", all.count, "drops:", drops, "hides:", hides)
        #expect(bad == 0)
        #expect(hides > 100 && drops > 1000)
        let names = Set(all.map(\.name))
        for required in ["incident-same-section", "cross-hidden", "hide-unit", "absent-key", "split-unit"] { #expect(names.contains(required), "missing \(required)") }
    }

    /// The incident (gdu.149): one drop of one key of a nine-key unit inside Visible moves that key only, and reports only that key.
    @Test func oneDropOfOneKeyOfNineMovesOneKey() throws {
        let unit: [Key: UInt32] = Dictionary(uniqueKeysWithValues: (10...18).map { (Key($0), 7) })
        let lay = Layout3(visible: [1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 2, 90], hidden: [3], alwaysHidden: [])
        let r = try DecisionCore.applyGesture(layout: lay, units: unit, immovable: [90], gesture: .drop(12, .visible, index: 0))
        #expect(r.layout == Layout3(visible: [12, 1, 10, 11, 13, 14, 15, 16, 17, 18, 2, 90], hidden: [3], alwaysHidden: []))
        #expect(r.moved == [12])
    }

    static let layout = Codec.encode(Layout3(visible: [1, 2, 90], hidden: [3], alwaysHidden: []))
    static let units: [UInt32] = [0]
    static let sys: [UInt32] = [1, 90]
    static let gst: [UInt32] = [0, 1, 1, 0]

    /// Malformed inputs are refused with `.malformedInput`, never answered with a default layout.
    @Test func malformedGestureInputsAreRefused() throws {
        _ = try Raw.gesture(Self.layout, Self.units, Self.sys, Self.gst)    // the control: valid
        let badLayouts: [[UInt32]] = [[], [1, 5, 0], Self.layout + [7], Array(Self.layout.dropLast()), [2, 5, 0, 0], [9, 1]]
        for l in badLayouts { #expect(throws: DecisionError.malformedInput, "layout \(l)") { _ = try Raw.gesture(l, Self.units, Self.sys, Self.gst) } }
        let badUnits: [[UInt32]] = [[], [3, 1, 2, 3], [2, 1, 2, 9], [2, 1], [1, 5]]
        for u in badUnits { #expect(throws: DecisionError.malformedInput, "units \(u)") { _ = try Raw.gesture(Self.layout, u, Self.sys, Self.gst) } }
        let badSys: [[UInt32]] = [[], [1], [0, 4], [3, 1, 2]]
        for s in badSys { #expect(throws: DecisionError.malformedInput, "sys \(s)") { _ = try Raw.gesture(Self.layout, Self.units, s, Self.gst) } }
        let badGestures: [[UInt32]] = [[], [2], [0, 1, 3, 0], [0, 1, 0, 2], [0, 1, 0, 1], [0, 1, 0, 0, 5], [1], [1, 2, 7], [1, 0, 9], [0, 1, 1, 0, 0], [4294967295]]
        for g in badGestures { #expect(throws: DecisionError.malformedInput, "gesture \(g)") { _ = try Raw.gesture(Self.layout, Self.units, Self.sys, g) } }
    }

    /// The decoder refuses an answer that is not what Lean produces.
    @Test func gestureAnswerDecoderIsStrict() {
        #expect(Codec.gestureResult([0, 0, 0, 0]) != nil)
        for w: [UInt32] in [[], [0, 0, 0], [0, 0, 0, 0, 0], [1, 5, 0, 0], [0, 0, 0, 3, 1], [0, 0, 0, 0, 0]] { #expect(Codec.gestureResult(w) == nil, "answer \(w)") }
    }

    /// The Swift encoder emits what Lean decodes: a full round trip through the real export for every section and index form.
    @Test func everyGestureFormRoundTrips() throws {
        let lay = Layout3(visible: [1, 2, 3], hidden: [4], alwaysHidden: [5])
        for s in LayoutSection3.allCases {
            for idx in [nil, 0, 1, 7] as [UInt32?] {
                let r = try DecisionCore.applyGesture(layout: lay, units: [:], immovable: [], gesture: .drop(2, s, index: idx))
                #expect(r.moved == [2])
                #expect(Set(r.layout.visible + r.layout.hidden + r.layout.alwaysHidden) == [1, 2, 3, 4, 5])
            }
        }
        let h = try DecisionCore.applyGesture(layout: lay, units: [:], immovable: [], gesture: .hideNotFitting([3, 1, 9]))
        #expect(h.layout == Layout3(visible: [2], hidden: [4, 3, 1], alwaysHidden: [5]))
        #expect(h.moved == [3, 1])
    }
}
