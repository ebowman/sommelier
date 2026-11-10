import Foundation
import DecisionCore

/// Wiring plan section 2: the actuator's answer to one drag, in the core's terms. A pure function.
///
/// | actuator result                                                          | core `Outcome` |
/// |--------------------------------------------------------------------------|----------------|
/// | `.verified`                                                              | `verified`     |
/// | `.failed(.userBusy)`                                                     | `busy`         |
/// | overflow refusal, `unsupportedItem`, `notFound`, the strip-not-allowed refusal | `refused` |
/// | everything else, including the strip-hold failures                       | `failed`       |
///
/// `posted` is ALWAYS the actuator's `lastMoveTouchedMouse` (a chevron click counts as a touch), whatever the outcome.
public enum OutcomeMapper {
    public static func map(_ result: ActuationResult, touchedMouse: Bool) -> (outcome: Outcome, posted: Bool) {
        (outcome(result), touchedMouse)
    }

    public static func outcome(_ result: ActuationResult) -> Outcome {
        switch result {
        case .verified: return .verified
        case .failed(let e, _):
            if case .userBusy = e { return .busy }
            if e.isOverflowRefusal || e.isStripNotAllowedRefusal { return .refused }
            switch e {
            case .unsupportedItem, .notFound: return .refused
            default: return .failed   // including isStripHoldFailure (a mechanismFailed with a bar-level message)
            }
        }
    }
}
