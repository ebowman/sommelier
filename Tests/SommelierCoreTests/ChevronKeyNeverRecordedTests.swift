import Foundation
import Testing
@testable import SommelierCore

// 9o9.14: the overflow chevron is MenuBarAgent's own control. It is never a record key, in any section, on any path.
@Suite struct ChevronKeyNeverRecordedTests {
    private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
    private let chev = ItemKey.module(name: MenuBarItem.overflowChevronName)
    private let clock = ItemKey.module(name: "Clock")

    @Test func predicateRecognisesOnlyTheChevronKey() {
        #expect(chev.isOverflowChevron && ItemKey.overflowChevron == chev)
        #expect(!clock.isOverflowChevron && !k("a").isOverflowChevron)
    }

    @Test func upgradeAdoptionDropsTheChevronFromRecordAndBar() {
        let out = LayoutEngine.adoptedVisible([k("a"), chev, k("b")], bar: [k("b"), chev, k("a")])
        #expect(out == [k("b"), k("a")])
        #expect(!LayoutEngine.adoptedVisible([k("a"), k("b")], bar: [k("b"), chev, k("a")]).contains(chev))
    }

    @Test func handDragAdoptionNeverRecordsTheChevron() {
        let rec = [k("a"), k("b"), k("c")]
        let obs = ObservedOrder(onBar: [k("c"), chev, k("a"), k("b")], parked: [], overflowChevron: chev)
        #expect(LayoutEngine.handDragAdopted(obs, record: rec).visible == [k("c"), k("a"), k("b")])
        // Even when the chevron is not flagged in the observation, its key is excluded.
        let obs2 = ObservedOrder(onBar: [k("c"), chev, k("a"), k("b")], parked: [])
        #expect(!LayoutEngine.handDragAdopted(obs2, record: rec).visible.contains(chev))
        // A stale record that still holds the key does not carry it forward.
        #expect(!LayoutEngine.handDragAdopted(obs, record: [k("a"), chev, k("b"), k("c")]).visible.contains(chev))
    }


    @Test func arrangeStillRendersTheFoldLineFromTheObservation() {
        let items = Dictionary(uniqueKeysWithValues: [k("a"), k("b")].map { ($0, ItemInfo(key: $0, title: "", axDescription: "\($0)", ownerPID: 1, ownerBundleID: "com.x", ownerName: "O", width: 30, isOnBar: true, systemOverflow: false)) })
        let obs = ObservedOrder(onBar: [k("a"), chev, k("b")], parked: [], systemOverflow: [k("a")], overflowChevron: chev)
        let s = ArrangeSections.make(observed: obs, layout: Layout(visible: [k("a"), k("b")]), items: items, perItem: [:],
                                     capabilities: { _ in Capability(canMove: true, canHide: true) }, awaiting: [])
        #expect(s.visible.rows.contains { $0.isBoundary })
    }

    @Test func decodeHealsAFileHoldingTheChevronInEverySection() throws {
        let json = #"{"visible":["module:Clock","module:Show Hidden Menu Bar Items","status:com.a::a"],"hidden":["module:Show Hidden Menu Bar Items"],"alwaysHidden":["module:Show Hidden Menu Bar Items","status:com.b::b"]}"#
        let r = try Layout.decode(Data(json.utf8))
        #expect(r.layout.visible == [clock, ItemKey(storeKey: "status:com.a::a")!])
        #expect(r.layout.hidden.isEmpty)
        #expect(r.layout.alwaysHidden == [ItemKey(storeKey: "status:com.b::b")!])
        #expect(r.warnings.filter { $0.hasPrefix("ignored chevron key in") } ==
                ["ignored chevron key in visible", "ignored chevron key in hidden", "ignored chevron key in alwaysHidden"])
        for s in LayoutSection.allCases { #expect(!r.layout.keys(in: s).contains(chev)) }
        // Healed once: re-encoding and decoding again produces no warning.
        let again = try Layout.decode(try JSONEncoder().encode(r.layout))
        #expect(again.warnings.isEmpty && again.layout.visible == r.layout.visible)
    }

    @Test func decodeChangesNothingElseForTheUsersShape() throws {
        let json = #"{"visible":["module:Clock","status:com.bat::bat","module:Show Hidden Menu Bar Items","status:com.mem::mem"],"hidden":["status:com.h::h"],"newItemPolicy":"hidden"}"#
        let r = try Layout.decode(Data(json.utf8))
        #expect(r.layout.visible.map(\.description) == ["module:Clock", "status:com.bat::bat", "status:com.mem::mem"])
        #expect(r.layout.hidden.map(\.description) == ["status:com.h::h"] && r.layout.newItemPolicy == .hidden)
        #expect(r.warnings == ["ignored chevron key in visible"])
    }

    @Test func codableDecodeAlsoNeverYieldsTheChevron() throws {
        let l = try JSONDecoder().decode(Layout.self, from: Data(#"{"visible":["module:Show Hidden Menu Bar Items","module:Clock"]}"#.utf8))
        #expect(l.visible == [clock])
    }

    @Test func layoutBuilderSkipsTheChevronItemAndKey() {
        func ri(_ key: ItemKey, chevron: Bool, x: Double) -> ResolvedItem {
            ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x", ownerName: "o", title: "t", axDescription: "", axIdentifier: "", frame: CGRect(x: x, y: 0, width: 24, height: 24), source: .appExtras, isOnMenuBar: true, isOverflowChevron: chevron), key: key, confidence: .exact)
        }
        let r = [ri(k("a"), chevron: false, x: 0), ri(chev, chevron: true, x: 30), ri(chev, chevron: false, x: 60), ri(clock, chevron: false, x: 90)]
        let l = LayoutBuilder.build(from: r).layout
        #expect(l.visible == [k("a"), clock] && !l.hidden.contains(chev))
    }
}
