import Foundation

public enum StatusLine {
    public static func text(lastError: EngineError?, isConverged: Bool, inFlight: Bool, trusted: Bool, conflicting: String?) -> String {
        if !trusted { return "Accessibility required" }
        if conflicting != nil { return "Bartender is running — paused" }
        switch lastError {
        case .permissionDenied?: return "Accessibility required"
        case .conflictingManager?: return "Bartender is running — paused"
        case .observe(let m)?: return "Error: \(m)"
        case .stoppedAfterFailures(let n)?: return "Error: stopped after \(n) failures"
        case .batchDrift(let e, let o)?: return "Error: order drifted (expected \(e), saw \(o))"
        case nil: break
        }
        return (isConverged && !inFlight) ? "Converged" : "Working…"
    }

    @MainActor
    public static func text(state: EngineState, trusted: Bool, conflicting: String?) -> String {
        text(lastError: state.lastError, isConverged: state.isConverged, inFlight: state.inFlight != nil,
             trusted: trusted, conflicting: conflicting)
    }
}
