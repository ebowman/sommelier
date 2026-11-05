import Testing
import Foundation
@testable import SommelierCore

// Bead sommelier-gdu.68: helper keys listed in a parent's Control Center entry resolve to that parent entry.
private typealias E = ControlCenterTrackedAppsStore.Entry
private let entries: [E] = [
    E(key: "com.noodlesoft.Hazel", isAllowed: false, menuItemKeys: ["86Z3GCJ4MF.com.noodlesoft.HazelHelper", "com.noodlesoft.Hazel"]),
    E(key: "at.obdev.littlesnitch", isAllowed: false, menuItemKeys: ["at.obdev.littlesnitch.agent", "at.obdev.littlesnitch"]),
    E(key: "com.robinlu.mac.Tooth-Fairy", isAllowed: false, menuItemKeys: []),
    E(key: "com.github.Squirrel", isAllowed: true, menuItemKeys: ["com.electron.ollama"]),
    E(key: "com.electron.ollama", isAllowed: true, menuItemKeys: []),
    E(key: "com.apple.ScriptMenuApp", isAllowed: false, menuItemKeys: []),
    E(key: "p1", isAllowed: true, menuItemKeys: ["shared.helper"]),
    E(key: "p2", isAllowed: true, menuItemKeys: ["shared.helper"]),
    E(key: "com.apple.parent", isAllowed: true, menuItemKeys: ["apple.helper"]),
]
private let r = TrackedEntryResolver(entries: entries)
private func st(_ o: String) -> ItemKey { .status(ownerKey: o, autosaveName: "Item-0") }

@Test func helperKeyResolvesToItsParentEntry() {
    #expect(r.trackedKey(for: st("86Z3GCJ4MF.com.noodlesoft.HazelHelper"), bundleID: nil) == "com.noodlesoft.Hazel")
    #expect(r.trackedKey(for: st("at.obdev.littlesnitch.agent"), bundleID: "at.obdev.littlesnitch.agent") == "at.obdev.littlesnitch")
    #expect(r.isViaParent(candidates: ["at.obdev.littlesnitch.agent"]))
}

@Test func ownEntryWinsAndUnknownIsNil() {
    #expect(r.trackedKey(for: st("com.electron.ollama"), bundleID: nil) == "com.electron.ollama")   // listed by Squirrel too
    #expect(r.trackedKey(for: st("com.noodlesoft.Hazel"), bundleID: nil) == "com.noodlesoft.Hazel")
    #expect(!r.isViaParent(candidates: ["com.noodlesoft.Hazel"]))
    #expect(r.trackedKey(for: st("com.unknown.app"), bundleID: nil) == nil)
    #expect(r.trackedKey(for: .module(name: "Clock"), bundleID: nil) == nil)
}

@Test func heuristicKeysUseTheirBundleId() {
    let h = ItemKey.heuristic(bundleID: "com.robinlu.mac.Tooth-Fairy", fingerprint: "", ordinal: 0)
    #expect(r.trackedKey(for: h, bundleID: nil) == "com.robinlu.mac.Tooth-Fairy")
    #expect(r.trackedKey(for: .heuristic(bundleID: "com.nobody", fingerprint: "", ordinal: 0), bundleID: nil) == nil)
}

@Test func ambiguousParentsAndAppleParentsDoNotResolve() {
    #expect(r.trackedKey(for: st("shared.helper"), bundleID: nil) == nil)   // two parents list it: never guess
    #expect(r.trackedKey(for: st("apple.helper"), bundleID: nil) == nil)    // Apple entries are never edited
}

@Test func capabilityOutcomes() {
    let rules = EngineFactory.makeCapabilityRules(resolver: r, bundleID: { _ in nil })
    #expect(rules.capability(for: st("86Z3GCJ4MF.com.noodlesoft.HazelHelper")).canHide)
    #expect(rules.capability(for: .heuristic(bundleID: "com.robinlu.mac.Tooth-Fairy", fingerprint: "", ordinal: 0)).canHide)
    #expect(!rules.capability(for: st("com.unknown.app")).canHide)
    let apple = rules.capability(for: st("com.apple.ScriptMenuApp"))
    #expect(!apple.canHide && apple.reason?.contains("System Settings") == true)
    // A nil resolver (unreadable store) stays optimistic; a key-only resolver resolves exact matches only.
    #expect(EngineFactory.makeCapabilityRules(resolver: nil, bundleID: { _ in nil }).capability(for: st("x.y")).canHide)
    let keysOnly = EngineFactory.makeCapabilityRules(tracked: ["com.noodlesoft.Hazel"], bundleID: { _ in nil })
    #expect(!keysOnly.capability(for: st("86Z3GCJ4MF.com.noodlesoft.HazelHelper")).canHide)
}

@Test func arrangeRulesUseTheResolver() {
    let rules = ArrangeCapabilities.rules(items: [:], resolver: r)
    #expect(rules.capability(for: st("at.obdev.littlesnitch.agent")).canHide)
}

@Test func storeEntriesFeedTheResolver() throws {
    // Round trip through the real store decoder: menuItemLocations keys end up in the resolver.
    let loc: (String) -> [String: Any] = { ["bundle": ["_0": $0]] }
    let list: [Any] = [loc("com.p"), ["location": loc("com.p"), "menuItemLocations": [loc("com.p.helper"), loc("com.p")], "isAllowed": false] as [String: Any]]
    let blob = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    let file = try PropertyListSerialization.data(fromPropertyList: ["trackedApplications": blob], format: .binary, options: 0)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gdu68-\(UUID().uuidString).plist")
    defer { try? FileManager.default.removeItem(at: url) }
    try file.write(to: url)
    let res = try #require(TrackedEntryResolver.current(store: ControlCenterTrackedAppsStore(url: url)))
    #expect(res.trackedKey(candidates: ["com.p.helper"]) == "com.p")
}

@Test func reconcilerNamesAppleAppsAccurately() {
    let apple = ItemKey.status(ownerKey: "com.apple.ScriptMenuApp", autosaveName: "s")
    let v = st("a.v")
    let caps: (ItemKey) -> Capability = { $0 == apple ? Capability(canMove: true, canHide: false, reason: "Apple apps are hidden only in System Settings > Menu Bar.") : Capability(canMove: true, canHide: true) }
    let l = Layout(visible: [v], hidden: [apple])
    let p = Reconciler().plan(observed: ObservedOrder(onBar: [v], parked: [apple]), layout: l, capabilities: caps, showHiddenSection: true)
    #expect(p.skipped.first?.reason.contains("Apple apps are managed only in System Settings") == true)
}
