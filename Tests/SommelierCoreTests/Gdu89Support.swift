import Foundation
import DecisionCore
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
    /// prove it is not full. The engine tests that are about something other than that launch proof start from "known not full" (the test rig seeds
    /// the core with three quiet reads via `coreSeedReadsForTests`).
    static func plain() -> LayoutEngine.Config { var c = LayoutEngine.Config(); c.assumeFullBarAtLaunch = false; return c }
    /// ejb.18: test-side view of the old flag. `false` = the rig supplies three real-shaped quiet chevronless complete reads (the proof "not full");
    /// `true` = the production default (no seed reads). Production code no longer has this flag nor fabricates reads.
    var assumeFullBarAtLaunch: Bool {
        get { coreSeedReadsForTests.isEmpty }
        set {
            let quiet = Read(kind: .poll, chevron: .absent, level: .complete, settled: true, stripOpen: false, drawn: [], pile: [], folded: [], trusted: [], nearFold: [])
            coreSeedReadsForTests = newValue ? [] : [quiet, quiet, quiet]
        }
    }
}
