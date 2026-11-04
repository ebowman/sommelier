import Foundation

/// Applies planned actions to an `ObservedOrder` the way a correct actuator would. Used by tests and dry runs.
public enum PlanSimulator {
    /// - `move`: removes the key and reinserts it relative to the target (no-op if the target is not on the bar).
    /// - `hide`: onBar -> parked. `show`: parked -> onBar at index `showInsertion(onBar.count)` (clamped); models
    ///   MenuBarAgent choosing the slot. Default is the end.
    public static func apply(_ action: PlannedAction, to order: ObservedOrder,
                             showInsertion: (Int) -> Int = { $0 }) -> ObservedOrder {
        var o = order
        switch action {
        case .move(let k, let rel):
            guard o.onBar.contains(k) else { return o }
            var bar = o.onBar
            bar.removeAll { $0 == k }
            switch rel {
            case .after(let t):
                guard let i = bar.firstIndex(of: t) else { return o }
                bar.insert(k, at: i + 1)
            case .before(let t):
                guard let i = bar.firstIndex(of: t) else { return o }
                bar.insert(k, at: i)
            case .leftmost: bar.insert(k, at: 0)
            case .rightmost: bar.append(k)
            }
            o.onBar = bar
        case .hide(let k):
            guard let i = o.onBar.firstIndex(of: k) else { return o }
            o.onBar.remove(at: i)
            o.parked.append(k)
        case .show(let k):
            guard let i = o.parked.firstIndex(of: k) else { return o }
            o.parked.remove(at: i)
            let at = max(0, min(showInsertion(o.onBar.count), o.onBar.count))
            o.onBar.insert(k, at: at)
        }
        return o
    }
}
