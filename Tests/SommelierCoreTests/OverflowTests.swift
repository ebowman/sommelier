import Testing
import CoreGraphics
@testable import SommelierCore

private func info(_ k: ItemKey, desc: String = "", title: String = "", owner: String = "Owner", w: CGFloat = 30, bar: Bool = false) -> ItemInfo {
    ItemInfo(key: k, title: title, axDescription: desc, ownerPID: 1, ownerBundleID: "x.y", ownerName: owner, width: w, isOnBar: bar)
}

@Suite struct OverflowTests {
    let a = ItemKey.module(name: "A"), b = ItemKey.module(name: "B"), c = ItemKey.module(name: "C")

    @Test func orderFollowsLayoutAndAbsentSkipped() {
        let l = Layout(hidden: [c, a, b])
        let e = OverflowEntries.make(layout: l, items: [a: info(a, desc: "A"), c: info(c, desc: "C", bar: true)])
        #expect(e.map(\.key) == [c, a])
        #expect(e[0].isOnBar)
    }

    @Test func alwaysHiddenOnlyWhenAsked() {
        let l = Layout(hidden: [a], alwaysHidden: [b])
        let items = [a: info(a, desc: "A"), b: info(b, desc: "B")]
        #expect(OverflowEntries.make(layout: l, items: items).map(\.key) == [a])
        #expect(OverflowEntries.make(layout: l, items: items, includeAlwaysHidden: true).map(\.key) == [a, b])
    }

    @Test func soleItemOwnerShowsAppNameNotDescription() {
        let s = ItemKey.status(ownerKey: "o.k", autosaveName: "i")
        // 9o9.15: the app name wins for a lone item; the description is only the fallback when the app name is empty.
        #expect(OverflowEntries.displayName(info(s, desc: " D ", title: "T")) == "Owner")
        #expect(OverflowEntries.displayName(info(s, desc: " D ", title: "T", owner: " ")) == "D")
        #expect(OverflowEntries.displayName(info(s, desc: "  ", title: "T", owner: "")) == "T")
        #expect(OverflowEntries.displayName(info(s)) == "Owner")
        let long = String(repeating: "x", count: 40)
        let n = OverflowEntries.displayName(info(s, owner: long))
        #expect(n.count == 24 && n.hasSuffix("…"))
        #expect(OverflowEntries.displayName(info(s, owner: String(repeating: "y", count: 24))).count == 24)
    }

    @Test func widthDefault() {
        let l = Layout(hidden: [a, b])
        let e = OverflowEntries.make(layout: l, items: [a: info(a, w: 0), b: info(b, w: 55)])
        #expect(e.map(\.width) == [28, 55])
    }

    @Test func mergeKeepsLastNonZeroWidthAndDropsVanished() {
        let prev = [a: info(a, w: 40), b: info(b, w: 33)]
        let fresh = [a: info(a, w: 0), c: info(c, w: 0)]
        let m = ItemInfo.merge(previous: prev, fresh: fresh)
        #expect(m[a]?.width == 40)
        #expect(m[b] == nil)
        #expect(m[c]?.width == 0)
        #expect(ItemInfo.merge(previous: prev, fresh: [a: info(a, w: 50)])[a]?.width == 50)
    }

    @Test func placementAlignsRightEdgeUnderBar() {
        let vis = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let f = OverflowPlacement.panelFrame(anchor: CGRect(x: 900, y: 790, width: 30, height: 24), menuBarBottomY: 800,
                                             screenVisible: vis, contentSize: CGSize(width: 200, height: 40))
        #expect(f == CGRect(x: 730, y: 760, width: 200, height: 40))
    }

    @Test func wideContentCapsWidthAndKeepsRightEdge() {
        let vis = CGRect(x: 0, y: 0, width: 1920, height: 1170)
        let anchor = CGRect(x: 1700, y: 1170, width: 22, height: 30)
        let f = OverflowPlacement.panelFrame(anchor: anchor, menuBarBottomY: 1170, screenVisible: vis,
                                             contentSize: CGSize(width: 3000, height: 40))
        #expect(f.width == 1536)
        #expect(f.maxX == anchor.maxX)
        #expect(f.minX >= 0)
    }

    @Test func narrowContentKeepsNaturalWidthAndRightEdge() {
        let vis = CGRect(x: 0, y: 0, width: 1920, height: 1170)
        let anchor = CGRect(x: 1082, y: 1170, width: 22, height: 30)
        let f = OverflowPlacement.panelFrame(anchor: anchor, menuBarBottomY: 1170, screenVisible: vis,
                                             contentSize: CGSize(width: 300, height: 40))
        #expect(f.width == 300 && f.maxX == anchor.maxX && f.maxY == 1170)
    }

    @Test func anchorNearLeftEdgeReducesWidth() {
        let vis = CGRect(x: 0, y: 0, width: 1920, height: 1170)
        let anchor = CGRect(x: 80, y: 1170, width: 22, height: 30)
        let f = OverflowPlacement.panelFrame(anchor: anchor, menuBarBottomY: 1170, screenVisible: vis,
                                             contentSize: CGSize(width: 900, height: 40))
        #expect(f.minX >= vis.minX)
        #expect(f.width == 94)   // anchor.maxX (102) - 0 - 8
        #expect(f.maxX == anchor.maxX)
    }

    @Test func maxWidthIsEightyPercent() {
        let vis = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(OverflowPlacement.maxWidth(anchor: CGRect(x: 950, y: 0, width: 20, height: 10), screenVisible: vis) == 800)
    }
}
