import Testing
@testable import SommelierCore

@Suite struct ArrangeMenuRulesTests {
    private func row(ghost: Bool = true, running: Bool = true, draggable: Bool = true, anchor: Bool = false) -> ArrangeRow {
        let k = ItemKey.status(ownerKey: "o", autosaveName: "a")
        return ArrangeRow(key: k, title: "t", ownerName: "o", ownerBundleID: nil, ownerPID: nil, badge: .none, draggable: draggable, canHide: true,
                          isAnchor: anchor, isGhost: ghost, isBoundary: false, notFitting: false, notRunning: !running, unit: HideUnitRule.ownerKeys.unit(of: k), unitMates: [], capabilityNote: nil)
    }

    @Test func ghostInteractiveRule() {
        #expect(ArrangeMenuRules.ghostInteractive(row()))
        #expect(!ArrangeMenuRules.ghostInteractive(row(running: false)))
        #expect(!ArrangeMenuRules.ghostInteractive(row(draggable: false)))
        #expect(!ArrangeMenuRules.ghostInteractive(row(anchor: true)))
        #expect(!ArrangeMenuRules.ghostInteractive(row(ghost: false)))
    }

    @Test func stepItemsAreAlwaysThereExceptForGhosts() {
        #expect(!ArrangeMenuRules.showsStepItems(isGhost: true))
        #expect(ArrangeMenuRules.showsStepItems(isGhost: false))
    }
}
