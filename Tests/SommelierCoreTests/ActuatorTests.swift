import Foundation
import Testing
@testable import SommelierCore

private func k(_ n: String) -> ItemKey { .status(ownerKey: "a.\(n)", autosaveName: n) }
private let A = k("A"), B = k("B"), C = k("C"), D = k("D")
private let wifi = ItemKey.module(name: "WiFi")

private func fake(_ rules: CapabilityRules = CapabilityRules(hasTrackedEntry: { _ in true })) -> FakeActuator {
    FakeActuator(order: [A, B, C, D], capabilities: rules)
}

@Test func fakeMoveRelations() async {
    let f = fake()
    #expect((await f.move(A, relation: .after(C))).isVerified)
    #expect(await f.order == [B, C, A, D])
    #expect((await f.move(D, relation: .before(B))).isVerified)
    #expect(await f.order == [D, B, C, A])
    _ = await f.move(C, relation: .leftmost)
    #expect(await f.order == [C, D, B, A])
    _ = await f.move(C, relation: .rightmost)
    #expect(await f.order == [D, B, A, C])
}

@Test func fakeMoveErrorsDoNotMutate() async {
    let f = fake()
    #expect((await f.move(k("Z"), relation: .leftmost)).error == .notFound)
    #expect((await f.move(A, relation: .before(k("Z")))).error == .notFound)
    #expect((await f.move(A, relation: .before(A))).error == .notFound)
    #expect(await f.order == [A, B, C, D])
}

@Test func fakeScriptedFailureOnNthCall() async {
    let f = fake()
    await f.failOnCall(2, .timeout)
    #expect((await f.move(A, relation: .rightmost)).isVerified)
    let r = await f.move(B, relation: .rightmost)
    #expect(r.error == .timeout)
    #expect(await f.order == [B, C, D, A])
    #expect((await f.move(B, relation: .rightmost)).isVerified)
    #expect(await f.calls.count == 3)
    #expect(await f.calls[1] == .move(B, .rightmost))
}

@Test func fakeHideAndBatch() async {
    let f = fake()
    #expect((await f.setHidden(A, true)).isVerified)
    #expect(await f.hidden == [A])
    #expect((await f.applyHiddenBatch([A: false, B: true, C: true])).isVerified)
    #expect(await f.hidden == [B, C])
    #expect(await f.calls.count == 2)
}

@Test func fakeBatchIsAllOrNothing() async {
    let rules = CapabilityRules(hasTrackedEntry: { $0 != C })
    let f = fake(rules)
    let r = await f.applyHiddenBatch([A: true, C: true])
    if case .failed(.unsupportedItem, _) = r {} else { Issue.record("expected unsupportedItem, got \(r)") }
    #expect(await f.hidden.isEmpty)
}

@Test func capabilityModuleCannotMoveOrHide() {
    let c = CapabilityRules(hasTrackedEntry: { _ in true }).capability(for: wifi)
    #expect(!c.canMove && !c.canHide && c.reason != nil)
}

@Test func capabilityUntrackedAppCannotHide() {
    let rules = CapabilityRules(hasTrackedEntry: { $0 == A })
    #expect(rules.capability(for: A) == Capability(canMove: true, canHide: true))
    let b = rules.capability(for: B)
    #expect(b.canMove && !b.canHide && b.reason != nil)
}

@Test func capabilityAppleAppsAndHeuristics() {
    let rules = CapabilityRules(hasTrackedEntry: { _ in true })
    let apple = rules.capability(for: .status(ownerKey: "com.apple.systemuiserver", autosaveName: "x"))
    #expect(apple.canMove && !apple.canHide)
    let h = rules.capability(for: .heuristic(bundleID: "a.b", fingerprint: "f", ordinal: 0))
    #expect(h.canMove && h.canHide && h.reason != nil)
    let h2 = CapabilityRules(hasTrackedEntry: { _ in false }).capability(for: .heuristic(bundleID: "a.b", fingerprint: "f", ordinal: 0))
    #expect(h2.canMove && !h2.canHide)
}

@Test func fakeRejectsUnsupportedMove() async {
    let f = FakeActuator(order: [A, wifi])
    if case .failed(.unsupportedItem, _) = await f.move(wifi, relation: .leftmost) {} else { Issue.record("expected unsupportedItem") }
    #expect(await f.order == [A, wifi])
}

@Test func fakeScriptedConflictingManager() async {
    let f = fake()
    await f.failOnCall(1, .conflictingManager("Bartender 7 is running"))
    #expect((await f.move(A, relation: .rightmost)).error == .conflictingManager("Bartender 7 is running"))
    #expect(await f.order == [A, B, C, D])
}
