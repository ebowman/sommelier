import Foundation
@testable import SommelierCore

extension Layout {
    /// gdu.89: the engine enforces only the order of `placed` keys. Tests written before that rule expect the whole visible order to be
    /// enforced; they build their layouts with this, which marks every visible key as user-placed (today's full-order behaviour).
    static func placedAll(visible: [ItemKey] = [], hidden: [ItemKey] = [], alwaysHidden: [ItemKey] = [],
                          newItemPolicy: NewItemPolicy = .visibleAtEnd) -> Layout {
        Layout(visible: visible, hidden: hidden, alwaysHidden: alwaysHidden, newItemPolicy: newItemPolicy, placed: visible)
    }
}
