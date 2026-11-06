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

struct BatchDriftSummaryTests {
    @Test func failedCount() {
        #expect(StatusLine.batchDriftSummary(expected: "all of 27 items in the requested state", observed: "failed: A, B, C; A: x, B: y")
                == "3 of 27 items did not reach the requested state (details in the log)")
    }
    @Test func singular() {
        #expect(StatusLine.batchDriftSummary(expected: "all of 5 items in the requested state", observed: "failed: A")
                == "1 of 5 items did not reach the requested state (details in the log)")
    }
    @Test func order() {
        #expect(StatusLine.batchDriftSummary(expected: "relative order kept: a, b", observed: "x") == "order drifted (details in the log)")
    }
    @Test func otherChange() {
        #expect(StatusLine.batchDriftSummary(expected: "no other item changes", observed: "x") == "another item changed during the batch (details in the log)")
    }
    @Test func fallback() {
        #expect(StatusLine.batchDriftSummary(expected: "something", observed: "else") == "batch not verified (details in the log)")
        let s = StatusLine.text(lastError: .batchDrift(expected: "all of 2 items in the requested state", observed: "failed: A, B"), isConverged: false, inFlight: false, trusted: true, conflicting: nil)
        #expect(s == "Error: 2 of 2 items did not reach the requested state (details in the log)")
    }
}
