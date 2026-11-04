import Testing
@testable import SommelierCore

struct StatusLineTests {
    func t(_ e: EngineError? = nil, conv: Bool = true, fl: Bool = false, trusted: Bool = true, c: String? = nil) -> String {
        StatusLine.text(lastError: e, isConverged: conv, inFlight: fl, trusted: trusted, conflicting: c)
    }
    @Test func states() {
        #expect(t() == "Converged")
        #expect(t(conv: false) == "Working…")
        #expect(t(fl: true) == "Working…")
        #expect(t(.observe("boom")) == "Error: boom")
        #expect(t(trusted: false) == "Accessibility required")
        #expect(t(.permissionDenied) == "Accessibility required")
        #expect(t(c: "Bartender 7 is running") == "Bartender is running — paused")
        #expect(t(.observe("x"), c: "B") == "Bartender is running — paused")
    }
}
