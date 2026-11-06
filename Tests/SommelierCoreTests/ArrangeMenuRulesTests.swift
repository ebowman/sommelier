import Testing
@testable import SommelierCore

@Suite struct ArrangeMenuRulesTests {
    @Test func stepItemsOnlyWhenPlacedOnly() {
        #expect(ArrangeMenuRules.showsStepItems(mode: .placedOnly))
        #expect(!ArrangeMenuRules.showsStepItems(mode: .macOSOwns))
    }

    @Test func placementMenuTitle() {
        #expect(ArrangeMenuRules.placementMenuTitle(row: true, mode: .placedOnly) == "Stop managing order")
        #expect(ArrangeMenuRules.placementMenuTitle(row: true, mode: .macOSOwns) == "Forget placement")
        #expect(ArrangeMenuRules.placementMenuTitle(row: false, mode: .placedOnly) == nil)
        #expect(ArrangeMenuRules.placementMenuTitle(row: false, mode: .macOSOwns) == nil)
    }

    @Test func visibleHint() {
        #expect(ArrangeMenuRules.visibleHint(mode: .macOSOwns) == "Order follows macOS; Command-drag items in the menu bar to reorder.")
        #expect(ArrangeMenuRules.visibleHint(mode: .placedOnly) == nil)
    }

    @Test func placementSymbol() {
        #expect(ArrangeMenuRules.placementSymbol(isPlaced: true, inert: false) == "pin.fill")
        #expect(ArrangeMenuRules.placementSymbol(isPlaced: true, inert: true) == "pin.slash")
        #expect(ArrangeMenuRules.placementSymbol(isPlaced: false, inert: false) == nil)
        #expect(ArrangeMenuRules.placementSymbol(isPlaced: false, inert: true) == nil)
    }

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

    @Test func stepItemsHiddenForGhosts() {
        for m in [OrderMode.placedOnly, .macOSOwns] {
            #expect(!ArrangeMenuRules.showsStepItems(mode: m, isGhost: true))
            #expect(ArrangeMenuRules.showsStepItems(mode: m, isGhost: false) == ArrangeMenuRules.showsStepItems(mode: m))
        }
    }
}
