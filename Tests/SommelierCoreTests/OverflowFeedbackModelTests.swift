import Foundation
import Testing
@testable import SommelierCore

@Suite struct OverflowFeedbackModelTests {
    private func entry(_ n: String) -> OverflowEntry {
        OverflowEntry(key: .status(ownerKey: "com.x.\(n)", autosaveName: "Item-0"), displayName: n, ownerBundleID: nil, ownerPID: 1, width: 28, isOnBar: false)
    }

    @Test func clearingOneKeyLeavesTheOthersError() {
        let (a, b) = (entry("a"), entry("b"))
        var m = OverflowFeedbackModel()
        m.fail(a, message: "A failed", in: [a, b])
        m.fail(b, message: "B failed", in: [a, b])
        #expect(m.errors.count == 2)
        m.clear(b.key)
        #expect(m.errors == [a.key: "A failed"])
        m.clear(a.key)
        #expect(m.errors.isEmpty)
    }

    @Test func failedEntryDroppedByRefreshStaysRenderedUntilCleared() {
        let (a, b, c) = (entry("a"), entry("b"), entry("c"))
        var m = OverflowFeedbackModel()
        m.fail(b, message: "the app is not running", in: [a, b, c])
        #expect(m.rendered([a, c]).map(\.key) == [a.key, b.key, c.key])
        #expect(m.rendered([a, b, c]).map(\.key) == [a.key, b.key, c.key])   // not duplicated when still listed
        m.clear(b.key)
        #expect(m.rendered([a, c]).map(\.key) == [a.key, c.key])
    }

    @Test func twoDroppedEntriesKeepTheirPositions() {
        let (a, b, c) = (entry("a"), entry("b"), entry("c"))
        var m = OverflowFeedbackModel()
        m.fail(c, message: "x", in: [a, b, c])
        m.fail(a, message: "y", in: [a, b, c])
        #expect(m.rendered([b]).map(\.key) == [a.key, b.key, c.key])
    }

    @Test func composesWithRealEntries() {
        let k = ItemKey.status(ownerKey: "com.x.tool", autosaveName: "Item-0")
        let items = [k: ItemInfo(key: k, title: "T", axDescription: "", ownerPID: 7, ownerBundleID: "com.x.tool", ownerName: "Tool", width: 24, isOnBar: false)]
        let layout = Layout(hidden: [k])
        let real = OverflowEntries.make(layout: layout, items: items)
        var m = OverflowFeedbackModel()
        m.fail(real[0], message: "not running", in: real)
        let gone = OverflowEntries.make(layout: Layout(), items: [:])
        #expect(m.rendered(gone).map(\.key) == [k])
    }
}
