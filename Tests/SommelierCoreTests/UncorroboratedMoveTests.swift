import Testing
import Foundation
import CoreGraphics
@testable import SommelierCore

// gdu.94: a hidden item's stale app-side frame (Airmail2Hookmark, build 226) must never be an order-move subject or a drag target.

private func k(_ n: String) -> ItemKey { .status(ownerKey: "com.x.\(n)", autosaveName: n) }
private func free(_: ItemKey) -> Capability { Capability(canMove: true, canHide: true) }
private func mi(_ n: String, x: CGFloat, join: JoinEvidence = .identifier, ccAllowed: Bool? = nil, ccHidden: Bool = false, stale: Bool = false) -> ResolvedItem {
    ResolvedItem(item: MenuBarItem(ownerPID: 1, ownerBundleID: "com.x.\(n)", ownerName: n, title: "", axDescription: "", axIdentifier: n,
                                   frame: CGRect(x: x, y: 3, width: 27, height: 24), source: .appExtras, isOnMenuBar: true, stale: stale,
                                   joinEvidence: join, hiddenInControlCenter: ccHidden, controlCenterAllowed: ccAllowed),
                 key: k(n), confidence: .exact)
}
private func plan(_ items: [ResolvedItem]) -> Plan {
    let layout = Layout(visible: [k("a"), k("airmail"), k("l"), k("z")])
    return Reconciler().plan(observed: ObservedOrder(resolved: items), layout: layout, capabilities: free, placed: [k("airmail")])
}

struct UncorroboratedMoveTests {
    // bar: a, airmail (placed, wants to sit after a, i.e. before l), l, z -- airmail currently observed after z
    private func bar(_ airmail: ResolvedItem) -> [ResolvedItem] {
        [mi("a", x: 100), mi("l", x: 140), mi("z", x: 180), airmail]
    }

    @Test func corroboratedJoinMoves() {
        let p = plan(bar(mi("airmail", x: 220)))
        #expect(p.actions == [.move(k("airmail"), .after(k("a")))])
        #expect(p.skipped.isEmpty)
    }

    @Test func noJoinPlansNoMoveAndSkips() {
        let p = plan(bar(mi("airmail", x: 220, join: .none)))
        #expect(p.actions.isEmpty)
        #expect(p.skipped.filter { $0.key == k("airmail") }.map(\.reason) == [Reconciler.uncorroboratedSkipReason])
    }

    @Test func ambiguousJoinAndControlCenterFlagsPlanNoMove() {
        for airmail in [mi("airmail", x: 220, join: .frameAmbiguous), mi("airmail", x: 220, ccAllowed: false), mi("airmail", x: 220, ccHidden: true)] {
            let p = plan(bar(airmail))
            #expect(p.actions.isEmpty)
            #expect(p.skipped.filter { $0.reason == Reconciler.uncorroboratedSkipReason }.count == 1)
        }
    }

    @Test func alreadyPlacedUncorroboratedKeyIsSilent() {
        let items = [mi("a", x: 100), mi("airmail", x: 140, join: .none), mi("l", x: 180), mi("z", x: 220)]
        let p = plan(items)
        #expect(p.actions.isEmpty)
        #expect(p.skipped.isEmpty)
    }

    // actuator predicate: the incident (stale app-side frame on another fresh item's slot)
    @Test func frameOverlappingAFreshItemIsNotTrustworthy() {
        let other = mi("TextInputMenuAgent", x: 1632)
        let subject = mi("airmail", x: 1632, join: .none)
        #expect(LiveActuator.frameTrustworthy(subject: subject, among: [other, subject]) != nil)
        #expect(LiveActuator.frameTrustworthy(subject: mi("airmail", x: 1700), among: [other]) == nil)
        #expect(LiveActuator.frameTrustworthy(subject: mi("airmail", x: 1700, ccHidden: true), among: []) != nil)
        #expect(LiveActuator.frameTrustworthy(subject: mi("airmail", x: 1700, ccAllowed: false), among: []) != nil)
        #expect(LiveActuator.frameTrustworthy(subject: mi("airmail", x: 1700, stale: true), among: []) != nil)
        // a stale neighbour does not count as a fresh occupant of the slot
        #expect(LiveActuator.frameTrustworthy(subject: subject, among: [mi("TextInputMenuAgent", x: 1632, stale: true)]) == nil)
    }
}
