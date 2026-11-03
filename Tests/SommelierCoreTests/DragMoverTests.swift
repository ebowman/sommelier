import XCTest
@testable import SommelierCore

final class DragMoverTests: XCTestCase {
    func item(_ b: String, _ id: String, desc: String = "", x: CGFloat = 100, src: MenuBarItemSource = .appExtras) -> MenuBarItem {
        MenuBarItem(ownerPID: 1, ownerBundleID: b, ownerName: b, title: "", axDescription: desc, axIdentifier: id,
                    frame: CGRect(x: x, y: 0, width: 24, height: 24), source: src, isOnMenuBar: true)
    }

    func testPlanCountAndTiming() {
        let p = DragPlan.make(from: CGPoint(x: 100, y: 10), toX: 200, steps: 10, stepDelay: 0.015, hold: 0.25)
        XCTAssertEqual(p.count, 13)
        XCTAssertEqual(p.map(\.kind).prefix(2), [.move, .down])
        XCTAssertEqual(p.last?.kind, .up)
        XCTAssertEqual(p.filter { $0.kind == .dragged }.count, 10)
        XCTAssertEqual(p[2].delayBefore, 0.25)
        XCTAssertEqual(p[3].delayBefore, 0.015)
        XCTAssertEqual(p[2].point.x, 110, accuracy: 0.001)
        XCTAssertEqual(p[11].point.x, 200, accuracy: 0.001)
        XCTAssertEqual(p.last?.point, CGPoint(x: 200, y: 10))
        XCTAssertTrue(p.allSatisfy { $0.point.y == 10 })
    }

    func testPlanLeftwardAndMinSteps() {
        let p = DragPlan.make(from: CGPoint(x: 100, y: 5), toX: 40, steps: 0, stepDelay: 0.01, hold: 0)
        XCTAssertEqual(p.filter { $0.kind == .dragged }.count, 1)
        XCTAssertEqual(p[2].point.x, 40)
    }

    func testResolverBundleAndSubstring() {
        let items = [item("a.b", "one", x: 1), item("a.b", "two", x: 2), item("c.d", "Dummy-A", desc: "Dummy A", x: 3)]
        if case .ambiguous(let c) = ItemResolver.resolve("a.b", in: items) { XCTAssertEqual(c.count, 2) } else { XCTFail() }
        if case .match(let m) = ItemResolver.resolve("a.b::two", in: items) { XCTAssertEqual(m.axIdentifier, "two") } else { XCTFail() }
        if case .match(let m) = ItemResolver.resolve("dummy-a", in: items) { XCTAssertEqual(m.ownerBundleID, "c.d") } else { XCTFail() }
        if case .none = ItemResolver.resolve("zzz", in: items) {} else { XCTFail() }
    }

    func testResolverExactBeatsSubstringAndOffBarIgnored() {
        var off = item("x.y", "Dummy-A2")
        off.isOnMenuBar = false
        let items = [item("c.d", "Dummy-A"), item("c.d", "Dummy-AB"), off]
        if case .match(let m) = ItemResolver.resolve("c.d::Dummy-A", in: items) { XCTAssertEqual(m.axIdentifier, "Dummy-A") } else { XCTFail() }
        if case .none = ItemResolver.resolve("x.y", in: items) {} else { XCTFail() }
    }

    func testProtected() {
        XCTAssertTrue(ItemResolver.protected(item("com.apple.MenuBarAgent", "com.apple.menuextra.clock", src: .agentHostedOnly)))
        XCTAssertFalse(ItemResolver.protected(item("c.d", "x")))
    }

    func testRelationAndDropX() {
        let t = item("t", "t", x: 100)
        let l = item("l", "l", x: 70), m = item("m", "m", x: 40), r = item("r", "r", x: 130)
        let bar = [m, l, t, r]
        // moving right (m left of t): after -> hover t; before -> hover t's left neighbor l
        XCTAssertEqual(DragTarget.dropX(for: .after("t"), moved: m, target: t, bar: bar), t.frame.midX + 6)
        XCTAssertEqual(DragTarget.dropX(for: .before("t"), moved: m, target: t, bar: bar), l.frame.midX + 6)
        // moving left (m right of t): before -> hover t; after -> hover t's right neighbor r
        let bar2 = [t, r, m]
        let m2 = item("m", "m", x: 160)
        XCTAssertEqual(DragTarget.dropX(for: .before("t"), moved: m2, target: t, bar: bar2 + []), t.frame.midX - 6)
        XCTAssertEqual(DragTarget.dropX(for: .after("t"), moved: m2, target: t, bar: [t, r, m2]), r.frame.midX - 6)
        // no neighbor: edge fallback
        XCTAssertEqual(DragTarget.dropX(for: .before("t"), target: t), 96)
        XCTAssertEqual(DragTarget.dropX(for: .after("t"), target: t), 128)
        XCTAssertEqual(DragTarget.dropX(for: .toX(55), target: nil), 55)
        XCTAssertTrue(DragTarget.holds(.before("t"), moved: "m", order: ["m", "t"]))
        XCTAssertFalse(DragTarget.holds(.before("t"), moved: "m", order: ["t", "m"]))
        XCTAssertTrue(DragTarget.holds(.after("t"), moved: "m", order: ["x", "t", "m"]))
        XCTAssertFalse(DragTarget.holds(.after("t"), moved: "m", order: ["t", "x", "m"]))
        XCTAssertTrue(DragTarget.holds(.toX(100), moved: "m", order: ["m"], movedMidX: 108))
        XCTAssertFalse(DragTarget.holds(.toX(100), moved: "m", order: ["m"], movedMidX: 140))
    }
}
