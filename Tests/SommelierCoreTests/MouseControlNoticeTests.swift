import Testing
@testable import SommelierCore

@Suite struct MouseControlNoticeTests {
    private let a = ItemKey.module(name: "A")
    private let b = ItemKey.module(name: "B")
    private func name(_ k: ItemKey) -> String { k == a ? "Alpha" : "Beta" }
    private func text(_ n: String) -> String { "Sommelier is moving \(n) on the menu bar. Hands off the mouse for a moment." }

    @Test func showsOnMoveOnce() {
        var n = MouseControlNotice()
        #expect(n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name) == .show(text: text("Alpha")))
        #expect(n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name) == nil)
    }
    @Test func hidesOnNil() {
        var n = MouseControlNotice()
        _ = n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name)
        #expect(n.update(inFlight: nil, enabled: true, displayName: name) == .hide)
        #expect(n.update(inFlight: nil, enabled: true, displayName: name) == nil)
    }
    @Test func hideAndShowActionsNeverShow() {
        var n = MouseControlNotice()
        #expect(n.update(inFlight: .hide(a), enabled: true, displayName: name) == nil)
        #expect(n.update(inFlight: .show(a), enabled: true, displayName: name) == nil)
        _ = n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name)
        #expect(n.update(inFlight: .hide(a), enabled: true, displayName: name) == .hide)
        _ = n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name)
        #expect(n.update(inFlight: .show(a), enabled: true, displayName: name) == .hide)
    }
    @Test func reshowsOnKeyChangeWithoutHide() {
        var n = MouseControlNotice()
        _ = n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name)
        #expect(n.update(inFlight: .move(b, .after(a)), enabled: true, displayName: name) == .show(text: text("Beta")))
    }
    @Test func disabledHidesThenStaysSilent() {
        var n = MouseControlNotice()
        #expect(n.update(inFlight: .move(a, .after(b)), enabled: false, displayName: name) == nil)
        _ = n.update(inFlight: .move(a, .after(b)), enabled: true, displayName: name)
        #expect(n.update(inFlight: .move(a, .after(b)), enabled: false, displayName: name) == .hide)
        #expect(n.update(inFlight: .move(a, .after(b)), enabled: false, displayName: name) == nil)
    }
    @Test func steadyStateNil() {
        var n = MouseControlNotice()
        for _ in 0..<3 { #expect(n.update(inFlight: nil, enabled: true, displayName: name) == nil) }
    }
}
