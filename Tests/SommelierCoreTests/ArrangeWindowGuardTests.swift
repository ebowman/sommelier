import Testing
@testable import SommelierCore

@Suite struct ArrangeWindowGuardTests {
    @Test func floatThenRestoreReactivates() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: true) == .float)
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false) == nil)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: false) == .restore(reactivate: true))
        #expect(g.update(inFlight: false, windowVisible: true, appActive: true) == nil)
    }

    @Test func appNotActiveAtStartDoesNotReactivate() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: false) == .float)
        #expect(g.update(inFlight: false, windowVisible: true, appActive: true) == .restore(reactivate: false))
    }

    @Test func hiddenWindowIsNeverTouched() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: false, appActive: true) == nil)
        #expect(g.update(inFlight: false, windowVisible: false, appActive: true) == nil)
        #expect(g.update(inFlight: true, windowVisible: false, appActive: true) == nil)
    }

    @Test func windowHiddenMidFlightRestoresWithoutReactivate() {
        var g = ArrangeWindowGuard()
        #expect(g.update(inFlight: true, windowVisible: true, appActive: true) == .float)
        #expect(g.update(inFlight: true, windowVisible: false, appActive: true) == .restore(reactivate: false))
        #expect(g.update(inFlight: false, windowVisible: false, appActive: true) == nil)
    }

    @Test func steadyStateEmitsNil() {
        var g = ArrangeWindowGuard()
        for _ in 0..<3 { #expect(g.update(inFlight: false, windowVisible: true, appActive: true) == nil) }
    }
}
