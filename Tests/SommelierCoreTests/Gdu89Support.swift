import Foundation
@testable import SommelierCore

extension Layout {
    /// gdu.89: the engine enforces only the order of `placed` keys. Tests written before that rule expect the whole visible order to be
    /// enforced; they build their layouts with this, which marks every visible key as user-placed (today's full-order behaviour).
    static func placedAll(visible: [ItemKey] = [], hidden: [ItemKey] = [], alwaysHidden: [ItemKey] = [],
                          newItemPolicy: NewItemPolicy = .visibleAtEnd) -> Layout {
        Layout(visible: visible, hidden: hidden, alwaysHidden: alwaysHidden, newItemPolicy: newItemPolicy)
    }
}

extension LayoutEngine.Config {
    /// ejb.15: the core decides order moves and, by design (docs/wiring-plan.md), makes none on a chevronless bar until three complete chevronless reads
    /// prove it is not full. The engine tests that are about something other than that launch proof start from "known not full" (the engine feeds
    /// the core the three quiet reads when `assumeFullBarAtLaunch` is false: TESTS ONLY, production keeps `true`).
    static func plain() -> LayoutEngine.Config { var c = LayoutEngine.Config(); c.assumeFullBarAtLaunch = false; return c }
}
