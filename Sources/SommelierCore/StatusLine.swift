import Foundation

public enum StatusLine {
    public static func text(lastError: EngineError?, isConverged: Bool, inFlight: Bool, trusted: Bool, conflicting: String?,
                            observationSettled: Bool = true) -> String {
        if !trusted { return "Accessibility required" }
        if conflicting != nil { return "Bartender is running — paused" }
        if let e = lastError { return errorText(e) }
        if !observationSettled { return "Observing (unsettled)" }
        return (isConverged && !inFlight) ? "Converged" : "Working…"
    }

    /// ejb.16: the menu's text is the core's, through the one renderer Arrange also uses (D10).
    public static func errorText(_ e: EngineError) -> String {
        switch e {
        case .permissionDenied: return "Accessibility required"
        case .conflictingManager: return "Bartender is running — paused"
        case .observe(let m): return "Error: \(m)"
        case .stoppedAfterFailures(let n): return "Error: stopped after \(n) failures"
        case .batchDrift(let e, let o): return "Error: " + batchDriftSummary(expected: e, observed: o)
        case .batchFailed(let m): return "Error: \(m)"
        case .decision(let m): return "Error: the decision core failed (\(m)); not moving anything"
        }
    }

    @MainActor
    public static func text(state: EngineState, trusted: Bool, conflicting: String?) -> String {
        CoreStatusText.text(state: state, trusted: trusted, conflicting: conflicting)
    }

    /// gdu.111: the status line never prints key lists. The raw `expected`/`observed` strings stay in the log and the per-item describe.
    public static func batchDriftSummary(expected: String, observed: String) -> String {
        let prefix = "all of "
        let suffix = " items in the requested state"
        if expected.hasPrefix(prefix), expected.hasSuffix(suffix), observed.hasPrefix("failed: "),
           let n = Int(expected.dropFirst(prefix.count).dropLast(suffix.count)) {
            let list = observed.dropFirst("failed: ".count).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let f = list.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return "\(f) of \(n) items did not reach the requested state (details in the log)"
        }
        if expected.hasPrefix("relative order kept") { return "order drifted (details in the log)" }
        if expected.hasPrefix("no other item changes") { return "another item changed during the batch (details in the log)" }
        return "batch not verified (details in the log)"
    }
}
