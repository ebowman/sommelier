import Foundation
import Testing
@testable import SommelierCore

@Suite struct ArrangeWindowGuardTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func floatThenRestoreReactivates() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: true) == .float)
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false) == nil)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: false) == .restore(orderFront: true, reactivate: true))
        #expect(g.update(inFlight: false, windowVisible: true, appActive: true) == nil)
    }

    // gdu.136 decision table, taken from the snapshot at float time.
    @Test func visibleAndKeyOrdersFrontAndReactivates() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false, windowKey: true) == .float)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: false) == .restore(orderFront: true, reactivate: true))
    }

    @Test func visibleButNotKeyOrdersFrontOnly() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false, windowKey: false) == .float)
        // activation state at restore time does not matter: the float-time snapshot decides
        #expect(g.update(inFlight: false, windowVisible: true, appActive: true, windowKey: true) == .restore(orderFront: true, reactivate: false))
    }

    @Test func occludedAtFloatTimeNeitherFloatsNorRestores() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: false, appActive: true, windowKey: true) == nil)
        #expect(g.update(inFlight: false, windowVisible: false, appActive: true) == nil)
    }

    @Test func aFloatShortlyAfterAReactivatingRestoreCountsAsActive() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: true, now: t0) == .float)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: true, now: t0.addingTimeInterval(5)) == .restore(orderFront: true, reactivate: true))
        // 0.5 s later activation has not settled (appActive false): still counts as active
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false, windowKey: false, now: t0.addingTimeInterval(5.5)) == .float)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: false, now: t0.addingTimeInterval(10)) == .restore(orderFront: true, reactivate: true))
    }

    @Test func aFloatLongAfterTheReactivationDoesNotCountAsActive() {
        var g = ArrangeWindowGuard()
        _ = g.update(inFlight: true, windowVisible: true, appActive: true, now: t0)
        _ = g.update(inFlight: false, windowVisible: true, appActive: true, now: t0.addingTimeInterval(5))
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false, now: t0.addingTimeInterval(8)) == .float)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: false, now: t0.addingTimeInterval(9)) == .restore(orderFront: true, reactivate: false))
    }

    @Test func aWindowCoveredMomentarilyWhileFloatedIsNotGone() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: true) == .float)
        #expect(g.update(inFlight: true, windowVisible: false, appActive: true) == nil)   // strip overlay / HUD covers it
        #expect(g.update(inFlight: false, windowVisible: false, appActive: false) == .restore(orderFront: true, reactivate: true))
    }

    @Test func windowGoneMidFlightRestoresWithoutOrderingFront() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: true) == .float)
        #expect(g.update(inFlight: true, windowVisible: false, appActive: true, windowOnScreen: false) == .restore(orderFront: false, reactivate: false))
        #expect(g.update(inFlight: false, windowVisible: false, appActive: true, windowOnScreen: false) == nil)
    }

    @Test func steadyStateEmitsNil() {
        var g = ArrangeWindowGuard()
        for _ in 0..<3 { #expect(g.update(inFlight: false, windowVisible: true, appActive: true) == nil) }
    }
}
