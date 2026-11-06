import Foundation
import Testing
@testable import SommelierCore

@Suite struct RefusalCalloutTests {
    private func key(_ n: String) -> ItemKey { .status(ownerKey: n, autosaveName: "a") }
    private func row(_ k: ItemKey, ghost: Bool = false) -> ArrangeRow {
        ArrangeRow(key: k, title: "\(k)", ownerName: "o", ownerBundleID: nil, ownerPID: nil, badge: .none, draggable: true, canHide: true,
                   isAnchor: false, isGhost: ghost, isBoundary: false, notFitting: false, notRunning: false, unit: HideUnitRule.ownerKeys.unit(of: k), unitMates: [], capabilityNote: nil)
    }

    @Test func showSetsFieldsAndIncrementsSerial() {
        let t = Date(timeIntervalSince1970: 1000)
        let a = RefusalCallout.show(nil, key: key("a"), why: "no", now: t)
        #expect(a.key == key("a") && a.text == "no" && a.shownAt == t && a.serial == 1)
        let b = RefusalCallout.show(a, key: key("b"), why: "nope", now: t.addingTimeInterval(1))
        #expect(b.key == key("b") && b.text == "nope" && b.serial == 2)
        #expect(RefusalCallout.show(b, key: key("b"), why: "nope", now: t).serial == 3)
    }

    @Test func activeForThreeSeconds() {
        let t = Date(timeIntervalSince1970: 1000)
        let c = RefusalCallout.show(nil, key: key("a"), why: "x", now: t)
        #expect(c.isActive(at: t.addingTimeInterval(2.9)))
        #expect(!c.isActive(at: t.addingTimeInterval(3)))
    }

    @Test func anchorNeedsNonGhostRow() {
        let k = key("a")
        #expect(RefusalCallout.anchor(for: k, in: [row(key("z")), row(k)]) == k)
        #expect(RefusalCallout.anchor(for: k, in: [row(k, ghost: true)]) == k)
        var notRunning = row(k, ghost: true); notRunning.notRunning = true
        #expect(RefusalCallout.anchor(for: k, in: [notRunning]) == nil)
        var fixed = row(k, ghost: true); fixed.draggable = false
        #expect(RefusalCallout.anchor(for: k, in: [fixed]) == nil)
        #expect(RefusalCallout.anchor(for: k, in: [row(key("z"))]) == nil)
    }
}
