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
}
